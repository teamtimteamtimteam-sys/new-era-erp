# CLAIM-GST-1 — an employee claim's amount is a receipt total, so GST is backed out, not added on top (2026-09-24)

- **The defect:** `decide_expense_claim` and `pay_medical_claim` passed the claimed amount to `record_expense` as a *net*
  amount, and `record_expense` added 9% on top. A claim is the total on a receipt, GST included. CLM-2026-0002 (100.00, TX)
  became a debt of 109.00; MC-2026-0001 (30.00, BL) became 32.70.
- **The fix (Tim's rulings Q1–Q11, all as recommended):** the two claim paths now say the amount includes GST; the tax is
  backed out with IRAS's tax fraction; the expense row stores the tax it posted, and every reader reads that.
- **Also in this cut:** the order-invoice GST fix was verified (it landed in AP-RECON-1 Batch B, nothing to do); the smoke
  clean-up is bounded (15 s per call, 120 s for the phase, exit **6** naming what was left).

Identities used throughout:
- **tim@**: `SET LOCAL ROLE authenticated` with sub `634c00f9-…` (`tim@evoltrya.test`, role `cfo`), reading **views**
  and `list_ledger_reconciliation()`.
- **postgres**: `rolbypassrls = t`, reading **base tables**, through the Management API.

---

## §G · What the grilling found (Step 0)

1. **The order-invoice fix landed in AP-RECON-1 Batch B.** The brief said Batch B's report was silent; its handback records
   it (§B0 "added mid-build", §B2). Verified separately against code and live (postgres, 14:12:29):
   `order_invoice_balance_all` on live contains `tax_amount_for`; `record_payment_internal` reads that view; the live bodies
   of `record_payment_internal`, `create_order_invoice` and `decide_expense_claim` are each contained verbatim in their
   mirrors. Fixture arm: **213 C11–C11g**; fault injection **F3** (tax dropped from the list → exit 4 on 213 C11).
   Live exposure: 2 order invoices, **0 taxed** (base `invoices`).
2. **The tax cannot be backed out while keeping "net + tax on the net".** At 9%, **16,514 of the 199,999 totals from
   0.01 to 1,999.99** cannot be written as net + round(net × 9%) (≈ 8.3%; measured by enumeration in Python with
   half-up rounding). Example: 10.11 → tax 0.83, net 9.28, but `tax_amount_for(9.28)` = 0.84. So the expense row must
   store its tax — a new column — and the five readers AP-RECON-1 Batch A pointed at `expense_payable_ccy` move to it.
3. **The over-posting split was wrong in `known-issues.md`.** EXP-2026-0008 is a *medical* claim coded **BL**; its 2.70 went
   into 6120, not input tax. Read as postgres from base `journal_lines` at 14:15: the 11.70 splits as
   **2000 +11.70 · 6120 +10.96 · 1400 +0.74** (EXP-0007 should be 91.74 + 8.26; EXP-0008 should be 27.52 + 2.48).
4. **Batch B's smoke hang had a different cause than it looked.** In the run's log `SMOKE_EXIT=124` comes *before*
   `✗ 收尾清扫抛出:fetch failed`: the process was stuck in `exitAfterCleanup`'s name-based sweep on a REST call with no
   timeout; the error was printed only after the supervisor's SIGTERM, which could not interrupt it because
   `exitAfterCleanup` is re-entrant. Recorded in `docs/handbacks/AP-RECON-1.md` §BV.
5. **Batch B's broken window closed with bounds** (`AP-RECON-1.md` §BW): start 12:00:00 CST (measured,
   `apply_migration.sh`); end **between 14:06:06 (measured: origin/main → `e8fcfb6c`, git's remote-ref log) and 14:12:29
   (derived: this session's first live read, database clock; Tim confirmed the deploy before it began)** — 2 h 06 min 06 s
   to 2 h 12 min 29 s. Bounds, not a measurement.

### Tim's rulings

| Q | ruling | where it landed |
|---|---|---|
| Q1 | add `expenses.tax_ccy`, backfilled from each row's posted tax line; five readers move to `amount_ccy + tax_ccy`; drop `expense_payable_ccy`; update fixtures 140 and 212 | §A1, §A3 |
| Q2 | tax = round(total × rate / (100 + rate), 2), half up; net = total − tax; one SQL function called by `record_expense` | §A2 `tax_included_in` |
| Q3 | a trailing GST-inclusive parameter; only the two claim paths pass true | §A2 |
| Q4 | TX → 1400, BL folded into the expense, ZP/EP/OP at 0%; no new refusals | fixture 215 A, C, D |
| Q5 | back out uniformly in the claim's own currency; no refusal | fixture 215 E |
| Q6 | record EXP-0007 / EXP-0008 in `known-wrong-until-cutover.md`, do not correct | done (two rows) |
| Q7 | the label, the confirm dialogs and the post-approval split, en and zh; no pre-approval preview | §A4 |
| Q8 | 15 s per call, 120 s per clean-up phase that a second signal cannot override, exit 6 naming what was left; 6 wins over 1, both logged | §S |
| Q9 | both forced-failure runs, reaping and reading live straight after each | §S |
| Q10 | the live proof in one rolled-back transaction, with before/after readings; name the approver | §P |
| Q11 | one session | this document |

---

## §A · What changed

Migration `db/migrations/2026-09-24-claimgst1-a-claim-amount-includes-its-gst.sql`, one transaction. Every function and
view is copied verbatim from its mirror (assembled by script, not by hand).

### A1 · `expenses.tax_ccy`

- `ADD COLUMN tax_ccy numeric NOT NULL DEFAULT 0`, at the end of the table (mirror: an `ALTER` block at the end of
  `db/tables/expenses.sql`, with its column comment).
- **Backfill:** from each expense's own `'GST on <code>'` credit line (`journal_lines.amount_ccy`). `expenses` is
  immutable (`trg_expenses_immutable`), so the trigger is disabled and re-enabled inside the migration's transaction —
  the same pattern FIN-2 used on `payment_allocations`.
- **The migration asserts the backfill, not only that it ran**, and rolls back if any fails: every taxed row with a rate > 0
  was filled; each filled value equals the old reader formula `tax_amount_for(amount_ccy, tax_rate_pct)` (so no list
  figure moves); each equals `tax_base` at the row's rate; no untaxed row carries tax.
  **Measured on live before applying** (postgres, base tables, 14:37:43, a read-only simulation of the same join):
  9 expenses · 3 taxed · 3 filled from exactly one line each · 0 differ from the old formula · 0 differ from `tax_base` ·
  0 stray. Fills: EXP-2026-0007 = 9.00, EXP-2026-0008 = 2.70, EXP-2026-0009 = 9.00.
- New `CHECK expenses_tax_ccy_shape`: no tax code ⇒ tax 0; a tax code ⇒ tax ≥ 0.

### A2 · Backing the tax out

- **New `tax_included_in(gross, rate)`** = `round(gross × rate / (100 + rate), 2)`.
- **`record_expense`** gains `p_amount_includes_tax boolean DEFAULT false` (a signature change, so the migration drops the
  old one first; `apply_migration.sh` replays the grants). When true: tax = `tax_included_in(p_amount, rate)`,
  net = `p_amount − tax`. When false (the default): exactly as before. Every later use of the amount (the net debit, the
  2000 credit, `amount_ccy`, `amount_base`, the WHT expectation, the capitalised cost) reads the net. The row stores
  `tax_ccy`, and the function returns `amount_ccy` and `tax_ccy` beside the existing keys.
- **Only two callers pass true:** `decide_expense_claim` and `pay_medical_claim`. The expense form and supplier bills keep
  "net + tax on top"; the form's hint "Enter the amount NET of GST" is still true.
- **Zero-rated and exempt:** ZP / EP / OP are 0%, so tax = 0 and net = the total. No new refusals (Q4).
- **Foreign currency:** backed out in the claim's own currency; base amounts are `round(net × fx)` and `round(tax × fx)`,
  the same two legs as before (Q5).
- **The GST return:** F5's input side reads the ledger (box 5 = the net lines tagged TX/ZP/BL, box 7 = account 1400), so it
  follows with no change to `f5_return`. A 109.00 TX claim now adds 100.00 to box 5 and 9.00 to box 7 (was 109.00 and 9.81).

### A3 · The five readers

`ap_open_items`, `ap_aging_asof`, `record_payment_internal` (the expense cap), `apply_prepayment` (the expense cap) and
`expense_claim_status` (`is_paid` / `is_owing`) read `amount_ccy + tax_ccy`. `expense_payable_ccy` is dropped.
`medical_claim_status` already compared in base (`amount_base + tax_base`) and needed no change to its judgement.

### A4 · What people see (en + zh)

- **Expense claim form** (`/me`): the label is now "Amount on the receipt (incl. GST)", with a hint: enter the receipt
  total, don't take the GST off.
- **Approval queue** (`/finance/claims`): expense-claim approval has **no confirm dialog** — it is a button with hint lines
  under it. The GST statement is a new hint line there (`expenseClaims.gstBackedOutHint`). The Q7 wording "both confirm
  dialogs" was mine; only the medical path has one.
- **Medical claim** (`/hr/claims/[id]`): the "Raise the expense" confirm dialog now says the GST is backed out of the
  receipt total; the claim form carries a hint.
- **After approval:** the decided list, the employee's own list and the medical claim page show the split,
  e.g. "100.00 net + 9.00 GST" — read from the posted expense through two columns appended to `expense_claim_status`
  (`expense_net_ccy`, `expense_tax_ccy`) and one to `medical_claim_status` (`expense_tax_base`). The page does no arithmetic.
- No pre-approval preview (Q7).

### A5 · Fixtures

- **New `215-a-claim-amount-includes-its-gst.sql`**, arms A (109.00 TX → 100 + 9, payable 109, 109.01 refused, 109.00
  settles, claim reads paid), A2 (120.50 → 110.55 + 9.95, the half-up case), B (10.11 → 9.28 + 0.83; the list is 10.11 and
  the check's AP unexplained is 0.00), C (medical 32.70 BL → 30.00 + 2.70, all into 6120, nothing into 1400), D (ZP 50.00 →
  50 + 0, a two-line entry), E (USD 109.00 at 1.2345 → 100 + 9; base 123.45 + 11.11; list 134.56), F (control: the expense
  form's 100 TX is still 100 + 9), G (the check's AP unexplained is 0.00 after A, B, E and F). Each arm first proves it
  cannot pass vacuously.
- **140 G** now asserts the 120.50 claim posts 110.55 + 9.95 and pays exactly 120.50.
- **212 A2** reads `amount_ccy + tax_ccy`.
- **77** pins `record_expense`'s signature on purpose; it went red exactly as its own comment predicts and now carries the
  sixth type.

---

## §V · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| fault injection (mirror edit → `--offline` → restore, SHA-256 byte-identical) | **F1** `decide_expense_claim` stops passing true → exit 4, **140 G + 215 A** (215 A: "实得 净 109.00 + 税 9.81") · **F2** `pay_medical_claim` stops passing true → exit 4, **215 C** (32.70 + 2.94) · **F3** `ap_open_items.open_ccy` recomputes `tax_amount_for(net)` → exit 4, **215 B** (list 10.12 / ledger 10.11) · **F4** `tax_included_in` truncates → exit 4, **140 G + 215 A2** (110.56 + 9.94) · **F5** the payment cap ignores tax → exit 4, **140, 212, 213, 215** · clean → exit 0 (`INJ_EXIT=0`, 310 s) |
| migration dress rehearsal (local cluster: rebuild from HEAD `e8fcfb6c` mirrors → apply the migration + the grants file → dump the catalogue; compare with a rebuild from the new mirrors) | `MIG_LOCAL=0`, `GRANTS_LOCAL=0`; catalogue (functions + ACLs, views + reloptions + ACLs, columns + defaults, constraints, policies, triggers, `expenses` column comments — 42,753 lines) **identical**. The comparison is not blind: the pre-migration dump differs from the new mirrors by 114 lines |
| `db/gate.py --offline`, final | `GATE_OWN_EXIT=0`, 49 s, **218** fixture files, 218 ✓ |
| forced-failure runs | §S |
| backup (`db/run_detached.sh`, token BACKUP) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-24-1447.dump`, 4.6 MB, TOC 6,091 (previous 6,078, floor 5,470), verified by the script's own `pg_restore --list` step, 15:05. It took 18 min (previous: 8); the dump's backend was checked live at 14:59 and 15:00 (`pg_stat_activity`: `EXECUTE dumpFunc(…)`, state changing every < 1 s) — slow, not stuck |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; pre-flight: 11 account codes all `is_system`; 7 CREATE FUNCTION = 5 replaced + 2 new (`tax_included_in`, and `record_expense` under its new signature after its DROP); 1 column added, 0 on a masked table; one warning, expected: `expense_payable_ccy` is dropped and not re-created. Backfill NOTICE: 3 taxed rows, all filled, each equal to the old formula and to `tax_base`. Committed atomically with the function-grant replay |
| `npm run types:gen` (after `NOTIFY pgrst, 'reload schema'` + 20 s) | `TYPES_OWN_EXIT=0` — `lib/database.types.ts` +11 / −4 (the column, the three view columns, the new parameter, `tax_included_in`; `expense_payable_ccy` gone) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` (34 checks + `next build`) | `BUILD_OWN_EXIT=0` |
| `node scripts/check-i18n.mjs` / `check-error-swallowing.mjs` | `I18N_OWN_EXIT=0` / `SWALLOW_OWN_EXIT=0` |
| `db/gate.py` full (`db/run_detached.sh`, token GATE) | **`GATE_EXIT=0`**, 500 s wall-clock — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ · 匿名面 ✓ (baseline 327) |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, started 15:19) | **`SMOKE_EXIT=0`** at 15:33 — 235 routes + probes: **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 671.7 s. It exited on its own; the bounded clean-up finished within its limits. Clean-up read at 15:33:48 as postgres from base tables (`auth.users`, `roles`, `user_roles`, `employees`): `smoke-%` users **0**, `probe-%` roles **0**, orphan grants (no user / no role) **0 / 0**, self-granted grants **0**, `ZZ-SMOKE-%` employees **0**; `.ephemeral/` empty; no smoke or `next dev` process left. The pre-run scratch-row report listed the same 6 stale rows as Batch B (pre-existing, report-only) |

## §P · Live proof

### Before and after

| reading | identity · object | before (14:46:52 CST) | after (15:08:39 CST) |
|---|---|---:|---:|
| `ap_open_items` n · Σ `open_base` | tim@ · **view** | 16 · 416,988.32 | 16 · 416,988.32 |
| `ar_open_items` n · Σ `open_base` | tim@ · **view** | 10 · 57,545.87 | 10 · 57,545.87 |
| EXP-2026-0007 / 0008 / 0009 `open_ccy` | tim@ · view | 109.00 / 32.70 / 109.00 | 109.00 / 32.70 / 109.00 (the backfill moved nothing) |
| account 2000 (debit − credit) | postgres · base `journal_lines` | −376,404.42 | −376,404.42 |
| account 1100 (debit − credit) | postgres · base | 43,002.12 | 43,002.12 |
| account 1400 input tax (debit − credit) | postgres · base | 18.00 | 18.00 |
| `journal_entries` count · `expenses` count | postgres · base | 82 · 9 | 82 · 9 |
| `approvals_enabled()` | postgres | true | true |
| `payment_requests` all / pending | postgres · base | 0 / 0 | 0 / 0 |
| `leave_requests` pending · `expense_claims` submitted · `medical_claims` submitted | postgres · base | 2 · 1 · 0 | 2 · 1 · 0 (pre-existing; nothing added) |
| list-vs-ledger, AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger, AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `expenses.tax_ccy` ≠ 0 | postgres · base | (column absent) | EXP-2026-0007 = 9.00 · 0008 = 2.70 · 0009 = 9.00 |
| `expense_payable_ccy` in `pg_proc` | postgres | 1 | 0 |

The pending submitted claim (CLM-2026-0004) and the two leave requests were there before this cut and are untouched.
Nothing was left pending by this cut.

### Refusals and read-backs — one rolled-back transaction

A `DO` block ending in `RAISE EXCEPTION 'PROOF_REPORT …'`, sent through the Management API as postgres at 15:08:29 CST.
Script: kept in the session's scratch directory, shape identical to AP-RECON-1's. Entry count 82 before, **84 inside**
(the claim's expense and its payment), **82 afterwards**; CLM-2026-0005 and EXP-2026-0010 do not exist afterwards
(postgres, base tables, 15:08:41).

**The plan named CLM-2026-0004 for the approval. It cannot be approved on live, and P1 records why.** It is SGD 1,000,
which `approval_level_for` puts at level 2; the level-2 role is `cfo`, whose only holder is tim@; and the claim has no
receipt and no no-receipt reason. So the posting was proven on a fresh claim inside the same transaction.
- **Claimant:** fusheng@ `c8116e6c-…` (EMP-2026-0006, role `warehouse`).
- **Approver:** **chooer@ `476bf8c8-…` (role `finance`)** — eligible at level 1 (`approval_level_eligible`) and holds
  `module.finance.edit`, which `record_expense` requires. chooer@ is CLM-2026-0004's own claimant, which is a second
  reason that claim could not be the vehicle.
- **Reads:** tim@, through the views and the check.

| # | action | result |
|---|---|---|
| P1 | tim@ approves CLM-2026-0004 with TX | `EXPENSE_CLAIM_NO_EVIDENCE\|CLM-2026-0004` — refused by name before anything posts |
| P2 | fusheng@ claims **SGD 109.00** (2026-09-20); chooer@ approves on 6120 with TX | CLM-2026-0005, level 1 → EXP-2026-0010: `amount_ccy` **100.00**, `tax_ccy` **9.00**, `tax_base` 9.00. Entry: 6120 Dr 100.00 (TX) · 1400 Dr 9.00 · 2000 Cr 100.00 · 2000 Cr 9.00. Deltas: 1400 **+9.00**, 2000 **−109.00** |
| P3 | read back as tim@ | list `open_ccy` **109.00**, `open_base` 109.00; claim `is_owing`; split column "100.00 + 9.00"; check AP: list 417,097.32 / ledger 376,513.42 / **unexplained 0.00** |
| P4 | chooer@ pays **109.01**, then **109.00** (`record_payment_internal`) | `ALLOC_EXCEEDS\|EXP-2026-0010\|109.01\|109.00`; 109.00 **accepted**; the expense leaves the list; claim `is_paid`; check AP: 416,988.32 / 376,404.42 / **unexplained 0.00** |

Before this cut, P2 would have posted 109.00 + 9.81 = 118.81.

Not exercised on live: the medical path (live has no approved, unposted medical claim) and a foreign-currency claim.
Fixture 215 C and E prove them on the rebuilt database.

## §S · The smoke clean-up is bounded (Q8, Q9)

**Why Batch B's smoke hung:** §G item 4.

**What changed** (`scripts/ephemeral.mjs`, shared by every script that makes throwaway accounts; `scripts/smoke-routes.mjs`):
- **Per call:** `del` and `req` (the clean-up plan's DELETE/PATCH) carry `AbortSignal.timeout(15 s)`. The smoke's own
  `rest()` carries the same once clean-up has begun (its `finally`, or `exitAfterCleanup`), which covers the name-based
  sweep, the call that hung.
- **Per phase:** `exitAfterCleanup` races the whole clean-up (plan → sweep) against a 120 s deadline. At the deadline it
  aborts whatever is in flight and stops waiting. A second signal cannot extend it: it gets the same promise, and that
  promise ends on its own.
- **Exit 6** when clean-up did not finish. It names every plan step that was not confirmed deleted (context + method +
  path), plus a sweep that did not finish. The plan stays on disk for `npm run reap:ephemeral`. 6 wins over 1 (and over a
  signal code); the original code is printed beside it. Nothing in the smoke used 6 before.
- **Unchanged on purpose:** REST calls during the route walk still have no per-call timeout; the supervisor's total
  bounds them. Recorded as `known-issues.md` § CLAIMGST1-SMOKE-WALK-CALLS-UNBOUNDED and queued; a bound there needs a
  measured slowest call first.
- **Two new injections:** `SMOKE_FORCE_FAIL_AT=cleanup-hang` (every clean-up call to the database hangs until aborted — the
  Batch B shape) and `cleanup-refused` (every one fails at once with `fetch failed`). Both fail after the grant, like
  `after-grant`. `EPHEMERAL_CLEANUP_DEADLINE_MS` exists only so the proof can reach the deadline branch; it is unset in
  normal runs and a malformed value exits 2.

**The two forced-failure runs**, each reaped and read back straight after. Every live figure: postgres, base tables
(`auth.users`, `roles`, `user_roles`, `employees`). Baseline 14:44:42: all 0.

| run | result |
|---|---|
| `cleanup-hang`, deadline 30 s, plus a **SIGTERM** at +25 s (during the clean-up) | `NODE_OWN_EXIT=6` after 47 s. The first step timed out at 15 s ("The operation was aborted due to timeout"); the deadline cut the second at 30 s; the SIGTERM changed nothing. Named: the grant `DELETE /rest/v1/user_roles?user_id=eq.01fccbe8-…`, the role `DELETE /rest/v1/roles?code=eq.probe-smoke-all-1790232305579`, the account `DELETE /auth/v1/admin/users/01fccbe8-…`, and "收尾阶段到了 30s 截止时刻"; "本来的退出码是 1;收尾没完成优先,退 6". Live **before reap** (14:45:42): smoke users 1, smoke roles 1, self-granted grants 1. `reap:ephemeral` → `REAP_OWN_EXIT=0`, 1 plan reaped. Live **after** (14:45:46): smoke users **0**, `probe-%` roles **0**, orphan grants (no user / no role) **0 / 0**, self-granted **0**, `ZZ-SMOKE-%` employees **0**; `.ephemeral/` empty; no smoke or `next dev` process |
| `cleanup-refused`, default 120 s | `NODE_OWN_EXIT=6` after 18 s (the clean-up itself under 0.1 s). Named the same three steps, "计划里有 3 步没确认删掉", and the unfinished name-based sweep with its three namespaces. Live before reap (14:46:19): 1 / 1 / 1. `REAP_OWN_EXIT=0`. Live after (14:46:23): all **0**; `.ephemeral/` empty; no process left |

## §W · The broken window — started, end PENDING

**Start: 2026-09-24 15:06:18 CST** — `db/apply_migration.sh`'s own line ("库已经是新的了 15:06:18"), in
`db/migration-windows.tsv`. (The script's "applied at" line reads 15:05:44; the commit came at 15:06:18.)
**End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database while the window is open (approvals ON):
- **Nothing is mis-posted, and no list or ledger figure moves.** The backfilled `tax_ccy` equals what the old readers
  computed, row by row (asserted in the migration), and the readings above are identical before and after.
- **Approving an expense claim, or raising a medical claim's expense, from the old app posts the NEW way.** Both
  paths run on the database: a 109.00 TX claim posts 100.00 + 9.00. The old screens still say "Amount", the old medical
  confirm text does not mention backing out, and the post-approval split is not shown. The only pending claim is
  CLM-2026-0004, which cannot be approved by anyone today (§P, P1).
- **The expense form** calls `record_expense` with named arguments and without the new parameter, so it resolves to the
  new signature with the default `false`, as before. It needs PostgREST's schema cache, reloaded at 15:06.
- **Pages reading `expense_claim_status` / `medical_claim_status`** use `select('*')` and ignore the appended columns.
- **Unaffected:** approvals, payment requests (0 exist), every other page and posting path.
