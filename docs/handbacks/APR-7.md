# APR-7 — a batch write-off, a processing rollback and a COD void happen only when the CFO approves them (2026-09-26)

The approvals effects are `docs/approvals.md` §3t; the matrix lines are `docs/role-matrix.md` (batch deletion · processing rollback ·
voiding a COD). **No version number is assigned** — the standing ruling is one number for the whole approval chain, announced at its end.
The name APR-7 is Tim's; the cuts after it follow in order: **APR-8** contract terms and pricing formulas · **APR-9** salary-change
request and asset disposal · **APR-10** GST filing approval and PO category.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `272b6345042dc7340c5cd0bde154d246f9c0ddb6` (APR-6).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity (`postgres`,
`rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · APR-6's broken window — closed with bounds, labelled by kind

Tim confirmed APR-6 pushed and deployed (2026-09-25); no Vercel timestamp was relayed.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 22:23:51 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 23:25:10 | **measured**: the push moved `origin/main` → `272b6345` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 23:31:13 | **derived**: this session's first read of `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 1 h 01 min 19 s, at most 1 h 07 min 22 s.** Also written into `docs/handbacks/APR-6.md` §5, together with **Tim's
acceptance of APR-6's two build decisions**: the 1100 / 2000 refusal also applies to reversal requests (so sales and prepayment
applications have no correction path yet — `docs/known-issues.md` § APR6-REVERSAL-OF-CONTROL-ACCOUNT-ENTRIES, now marked accepted) and a
blank reversal reason keeps its own code.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code from the mirrors; live read as `postgres`, base tables, 2026-09-25 23:31):
1. All three were one step for warehouse and admin (`action.batch_write_off` · `action.processing_rollback` · `action.issue_cod`, each
   held by admin · warehouse only).
2. **A write-off can void a certificate even when the batch is empty** — `soft_delete_inbound_batch` calls `refresh_cod_for_batch`, and
   all three empty live receipts carry a COD (two issued).
3. **A rollback reaches past the lock**: PROC-2026-0009 (2026-07-03, locked before 2026-08-01) could be rolled back and would void the
   issued COD-2026-0002 with no replacement — the quantity ledger is not locked by design (FIN-32), value reverses today.
4. The CFO cannot read the certificate table (its read policy is `action.issue_cod`); warehouse does not hold `data.view_prices`.
5. A direct `writeoff` / `adjustment` movement insert (`module.inventory.edit`) looked like a bypass; it is not one on its own (the
   deferred ledger invariant) — to be probed live.

**Tim accepted all nine recommendations (Q1–Q9)**; the stopping line (ship APR-7a if the whole cut did not fit) was **not needed** —
the whole cut shipped.

## §1 · What shipped

Migration `db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql` (2,676 lines, built by
`db/scripts/build_apr7_migration.py` from the mirrors; 28 `CREATE FUNCTION`: 7 replaced · 21 new). **No new permission code**, so "every
new code also goes to admin" had nothing to grant. It proves itself before COMMIT: approvals on; grants unchanged; the pending set
unchanged; `approval_log`, journal entries and lines, Σ debits, movements, deleted batches, reversed runs and certificate statuses
unchanged; `warehouse_requests` empty with no write policy; both freeze triggers present; every internal not executable by
`authenticated`; the old rollback / void doors only refuse; both one-step delete doors ask `batch_write_off_needs_request`; the chain row
is level 2 only; the new chain has a decider; **every pending document — now including every request chain (Q9) — has a decider who is
not its own party**.

| Q | built |
|---|---|
| Q1 | `batch_write_off_needs_request`: an inbound batch needs the CFO when stock is left (priced or not) or it carries an **issued** certificate; an output batch when stock is left. Empty batches are still deleted in one step by warehouse (`soft_delete_*` keep only that case) |
| Q2 | `warehouse_requests` — kinds `write_off_inbound` · `write_off_output` · `rollback` · `cod_void`, one subject column each (`kind_shape` + a `num_nonnulls = 1` twin for the relation graph). Doors `submit_inbound_write_off_request` · `submit_output_write_off_request` · `submit_rollback_request` · `submit_cod_void_request` (each its own code) → `warehouse_request_submit_internal`; `decide_warehouse_request`; `withdraw_warehouse_request`. Submit dry-runs the approval path (`warehouse_request_dry_run`, PQ005, flushing the deferred ledger / bucket / balance triggers). Approvals off → born approved, `auto_approved` |
| Q3 | `guard_warehouse_request_freeze` on `inventory_movements` (every movement on a subject batch, or on any output of a run whose rollback waits → `WAREHOUSE_REQUEST_FREEZES_BATCH`) and on `receipt_price_requests`; only the request's own execution passes (`evoltrya.warehouse_request_ctx`). `warehouse_request_touches` / `warehouse_request_conflict`: a batch, its certificate and a run that consumes it carry at most one waiting request (`WAREHOUSE_REQUEST_OPEN`), across kinds |
| Q4 | effective and valued on the approval day (the write-off trigger's own `deleted_at` / `CURRENT_DATE`); the payable check runs at submit (dry run) and again at approval |
| Q5 | a run dated inside a locked period may be rolled back; `snapshot.locked_period` / `locked_before` and `cods_voided` are shown on the CFO panel before approval |
| Q6 | `deleted_by` / `voided_by` = the raiser (`*_internal(…, p_deleted_by)`, `void_cod_internal(…, p_voided_by)`); the CFO on the request and in `approval_log` |
| Q7 | `rollback_processing_run` and `void_cod` refuse `WAREHOUSE_NEEDS_APPROVED_REQUEST` after their code check; bodies in `*_internal`, revoked. Direct-movement probe in the live proof (§3 A6–A8) |
| Q8 | engine: `approval_chain_gates` row (level 2, `module.finance.view` + `data.view_prices`) · `approval_pending_documents` arm (`blocks_disable`, `fixed_level` 2) · `approval_log` type + read branch · `record_approval_decision` branch · `operations_now` / reminder `warehouse_request_pending` · `assert_other_decider` → `WAREHOUSE_REQUEST_NO_OTHER_DECIDER`. Readers: `warehouse_requests_visible()` (amount `NULL` without `data.view_prices`), the submit-time `snapshot` for the CFO |
| Q9 | the migration's pending-decider proof asks `approval_deciders` document by document for every request chain |

**Screens (en / zh):**
- `/inventory` — a requests panel at the top: every waiting request with its batch / run / certificate, material, supplier, quantity,
  processing date, the outputs it voids and inputs it restores, the value it removes («Restricted» without `data.view_prices`), the
  reason, **the locked-period sentence and the certificates it voids**; Approve / Reject (visible, disabled with the reason without
  `module.finance.view` + `data.view_prices`) and Withdraw (the raiser, or that kind's code); the ten most recently settled below.
  Anchors `#wr-<id>` for the dashboard reminder.
- `/inbound` and `/output` — the delete button becomes **Request write-off** where the CFO is needed (stock left, or an issued
  certificate); an empty batch keeps its one-step Delete. Both are visible, unpressable and name the waiting request when one touches the
  batch.
- `/operation/processing/[id]` — **Request rollback** (the consequence sentence stays in the dialog); disabled with the waiting request.
- `/inbound/[id]/edit` — the certificate panel's Void becomes **Request void**; issuing is unchanged (warehouse, no approval).

**Fixtures:** 226 (new, arms A–N including its own fault injection — dropping the freeze trigger lets the movement through) · 205
(own-document gaps 9 → 10) · 111 (43 arms) · 103 (passes via the `num_nonnulls` twin) · 85 · 195 · 222 keep their door arms and now expect
`WAREHOUSE_NEEDS_APPROVED_REQUEST` or the request path · 17 more call the `*_internal` bodies (their subject is the write-off / rollback
arithmetic). `db/check_mirrors.py` allowlists the revoked internals; `scripts/check-document-registry.mjs` 234 → 235 tables;
`scripts/check-i18n.mjs` reads the new prefixes from the table and the error-code set.

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | `GATE_OWN_EXIT=0` (53 s) |
| static build checks before the migration (34, each run alone) | all exit 0 once `EXPECTED_TABLES` moved 234 → 235 |
| dry run of the migration file on live (`COMMIT` → grants + probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`; probe: `warehouse_requests` 0, `authenticated` can run `rollback_processing_run_internal` = f, `submit_rollback_request` = t |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-26-0028.dump`, TOC 6,369 (previous 6,336, floor 5,702), 00:50 |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight 28 `CREATE FUNCTION` (7 replaced · 21 new); proof NOTICEs: 1 decider (tim@), 9 pending documents each with a decider |
| `npm run types:gen` (after `NOTIFY pgrst`) | `TYPES_OWN_EXIT=0` (+331 / −1 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0` (480 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ · anon surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`node scripts/smoke-routes.mjs`, detached, 01:10 → 01:41) | `SMOKE_EXIT=0` — 236 routes + the probes; 229 timed, median 5,591 ms. Clean-up read back as `postgres` (base tables, 01:41): `auth.users` 7, 0 ephemeral; `roles` 13, 0 ephemeral; 7 unrevoked grants; `.ephemeral/` empty. The six stale `ZZ-SMOKE-*` rows it reports (562–1,204 h old) predate this cut and are left as reported |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-25-apr7-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, started 2026-09-26 00:56 CST, as `postgres` switching to each real account under `authenticated`).

| cell | who | what | result |
|---|---|---|---|
| S0 | postgres | before | JE 82 · movements 107 · `warehouse_requests` 0 · 1200 61,387.92 · 1220 134.86 · 5200 59,732.00 |
| A1–A4 | fusheng@ | the four old doors: rollback PROC-2026-0225 · void COD-2026-0001 · delete IN-2026-0179 (300 kg) · delete OUT-2026-0187 (60 kg) | `WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|PROC-2026-0225` · `…|cod_void|COD-2026-0001` · `…|write_off_inbound|IN-2026-0179` · `…|write_off_output|OUT-2026-0187` |
| A5 | fusheng@ | `rollback_processing_run_internal` (the body) | `permission denied for function rollback_processing_run_internal` |
| A6–A8 | fusheng@ | **Q7 probe**, one table per call: a direct `writeoff` movement · `remaining_qty = 0` · `deleted_at` | `LEDGER_INVARIANT|IN-2026-0179|300|0` · `LEDGER_INVARIANT|IN-2026-0179|0|300` · `SOFT_DELETE_NO_DIRECT_UPDATE|inbound_batches|IN-2026-0179`; no row left |
| B1 / B2 | fusheng@ · postgres | request a write-off of IN-2026-0179 (unpriced) | `IN-2026-0179 · write-off #1`, submitted, amount 0, batch and movements untouched · pending arm `blocks_disable`, `fixed_level` 2, subject NULL, deciders: tim@ |
| B3 / B4 | fusheng@ | a movement on the frozen batch · a second request | `WAREHOUSE_REQUEST_FREEZES_BATCH|IN-2026-0179|IN-2026-0179 · write-off #1` · `WAREHOUSE_REQUEST_OPEN|IN-2026-0179|…` |
| B5 / B6 / B7 | admin@ · fusheng@ · chooer@ | the CFO's other account raises · a priced batch still owed (IN-2026-0012) · finance raises | `WAREHOUSE_REQUEST_NO_OTHER_DECIDER|OUT-2026-0187 · write-off #1` · `INBOUND_HAS_OPEN_PAYABLE|IN-2026-0012|10000.00` · `PERMISSION_DENIED|action.batch_write_off`; no row left by any |
| C | fusheng@ · sandra@ · chooer@ · tim@ | decide | `PERMISSION_DENIED|module.finance.view` · `APPROVAL_NOT_AUTHORISED|2|cfo` ×2 · reject with a blank reason `WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED|…` |
| D1 / D2 | tim@ · postgres | approve | IN-2026-0179 deleted, `deleted_by` fusheng@, reason as raised; `writeoff` −300 dated 2026-09-26; no journal entry (unpriced) · log `submitted L2 fusheng@ → approved L2 tim@`, `self_decided` false |
| E1 / E2 | fusheng@ · tim@ | write off OUT-2026-0187 (60 × 2.2477) | dry run 134.86 · JE-2026-0080 posted (`writeoff`), 1220 134.86 → 0.00, 5200 59,732.00 → 59,866.86, `deleted_by` fusheng@ |
| F0 / F0b | fusheng@ · postgres | rollback PROC-2026-0225 **as live stands** | refused by `processing_runs_operation_type_required` — **all 10 live runs have no operation type** (§5, registered). Proof-only, rolled back: operation type set on PROC-2026-0225 / 0009 so the path can be walked |
| F1 / F2 | fusheng@ · tim@ | rollback PROC-2026-0225 | a movement on its output OUT-2026-0380 → `WAREHOUSE_REQUEST_FREEZES_BATCH|OUT-2026-0380|PROC-2026-0225 · rollback #1` · approved: reversed, `deleted_by` fusheng@, outputs voided, IN-2026-0180 restored to 100,000 |
| G1 / G2 | fusheng@ · chooer@ | rollback PROC-2026-0009 (locked period) — raise, then withdraw | snapshot `locked_period` true (before 2026-08-01), `cods_voided` ["COD-2026-0002"] · chooer@ withdraw → `PERMISSION_DENIED|action.processing_rollback`; fusheng@ → withdrawn; COD-2026-0002 still issued |
| H1 / H2 | fusheng@ · tim@ | void COD-2026-0001 | public verification while waiting: **issued** · approved: void, `voided_by` fusheng@, no replacement; public verification **void** (`replaced_by_code` null) |
| I1 | tim@ | reject IN-2026-0321 with a reason | rejected; IN-2026-0321 untouched (800) |
| J1 / J2 | postgres | end | 0 waiting (approved 4 · rejected 1 · withdrawn 1); pending documents: expense_claim 1 · JE 83 · 1200 61,387.92 · 1220 0.00 · 5200 59,866.86 |
| L | tim@ (views) | list vs ledger before / after the lifecycle | AP 416,988.32 / 376,404.42 · AR 57,545.87 / 43,002.12 — **unexplained 0.00 both sides, both times** |

**Before and after readings** — `db/scripts/2026-09-25-apr7-readings.sql` (part 1 as `postgres`, base tables; part 2 as tim@ on
views; part 3 each account as itself), before at 00:27:19, after at 01:41 (after the proof and the smoke). The two outputs were diffed:
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); pending — 1 expense claim (1,000.00),
  2 leave, 1 medical approved-unpaid, 5 open stocktakes, 0 PO / payment / payroll / receipt-price / invoice / journal requests, 0 shipping
  releases; `approval_pending_documents()` = 1 expense claim; journal entries 82 (by source type unchanged; `writeoff` 3), journal lines
  184, Σ debits 1,636,102.89; movements 107 (by type unchanged); approval_log 14; batches (inbound 24 / 9 deleted · output 20 / 6
  deleted), runs 10 live / 4 reversed; certificates issued 2 (COD-2026-0001 · 0002), pending 1; balances 1000 −127,593.48 · 1100
  43,002.12 · 1200 61,387.92 · 1220 134.86 · 2000 −376,404.42 · 5200 59,732.00; AP list 416,988.32 / ledger 376,404.42, AR list
  57,545.87 / ledger 43,002.12, **unexplained 0.00 both sides**; catalogue 66; the three codes held by admin · warehouse; every role's code
  count and md5 (admin 65 `485022c5…` · cfo 30 `730763e8…` · finance 38 `49745fb9…` · warehouse 24 `a3e9b958…` · the rest unchanged) and
  every account's `current_user_permissions()`; 7 unrevoked grants.
- **changed, as intended:** `warehouse_requests` exists (0 rows, 0 waiting; before: absent); the moved bodies and the new doors exist —
  `authenticated` can execute `rollback_processing_run_internal` / `soft_delete_inbound_batch_internal` / `void_cod_internal(…, uuid)`:
  **f**, the four submit doors and `decide_warehouse_request`: **t**; the old three-argument `void_cod_internal` is gone; freeze triggers
  0 → **2**. The four old doors stay executable (they refuse by name).
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration's own proof
  printed each — CLM-2026-0004 → tim@; leave → admin@, tim@; MC-2026-0001 → admin@, chooer@; stocktakes → chooer@; warehouse_request
  deciders: 1).

## §4 · Doors closed, and who can no longer do what (approvals on)

**Closed:** a one-step write-off of any batch with stock or an issued certificate · a one-step rollback · a one-step certificate void ·
calling the moved bodies directly. Direct `deleted_at`, run status and certificate status were already closed and are re-asserted; a
direct movement or `remaining_qty` write cannot stand on its own (the deferred invariant). **Named, not closed:** a stocktake counted to
zero (APR7-STOCKTAKE-IS-A-SECOND-WRITE-OFF-PATH).

- **Fu Sheng (warehouse):** can no longer write off a batch with stock or an issued certificate, roll back a run, or void a certificate
  in one step — each is a request the CFO approves; can withdraw its own. Still deletes empty batches and issues certificates, unchanged.
- **admin@:** holds the same three codes, but a request raised from admin@ is refused at submit (`WAREHOUSE_REQUEST_NO_OTHER_DECIDER` —
  same person as tim@, level 2's only real holder); cannot decide (no `cfo`). Keeps the empty-batch delete.
- **tim@ (cfo):** newly decides every write-off, rollback and certificate void, on `/inventory`. Raises nothing (none of the three codes).
- **Everyone else:** unchanged — nobody else holds any of the three codes.
- **No document is left with only its raiser eligible:** warehouse requests → tim@ (proof NOTICE: 1 decider).

## §5 · Findings registered on the way

- **APR7-LEGACY-RUNS-CANNOT-ROLL-BACK** — all 10 live runs have `operation_type_code` NULL (test residue under a NOT VALID CHECK), so none
  can be rolled back; the old one-step door hit the same constraint. APR-7 moves the refusal to submit (dry run), shown as the shared
  fallback sentence with the raw text in the detail. Tim decides what to do with the residue.
- **APR7-STOCKTAKE-IS-A-SECOND-WRITE-OFF-PATH** · **APR7-AUTO-VOID-REASON-READS-AS-REVERSAL** · **APR7-OUTPUT-STATE-DIRECTLY-EDITABLE** —
  `docs/known-issues.md`.
- Every priced live receipt still owes its supplier (IN-2026-0001 · 0003 · 0012 · 0029 · 0156 · 0181 · ZZ-PROCCOST1-DEMO; `postgres`,
  base tables, 2026-09-26), so none of them can be written off until paid or re-priced — the existing AP-RECON-1 rule, now enforced at
  submit and at approval.

## §6 · The broken window — started, end PENDING

**Start: 2026-09-26 00:54:32 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line reads
00:51:34). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Writing off a batch with stock or an issued certificate is refused for everyone** — the old Delete buttons on `/inbound` and
  `/output` call `soft_delete_*`, which now refuse `WAREHOUSE_NEEDS_APPROVED_REQUEST|…`; the old copy has no sentence for that code, so
  it shows the generic unexpected-error text. There is no screen to raise a write-off request until the deploy. **Empty batches still
  delete.**
- **Rolling back a run is refused for everyone** — the old button calls `rollback_processing_run` → `WAREHOUSE_NEEDS_APPROVED_REQUEST|…`
  (generic text). On live every run was already refused (APR7-LEGACY-RUNS-CANNOT-ROLL-BACK).
- **Voiding a certificate is refused for everyone** — the old Void calls `void_cod` → the same code (generic text).
- **Unaffected:** issuing certificates, receiving, processing, shipping, stocktakes, every other approval chain, the switch, everything
  pending, and every other screen. **Live impact:** nothing was waiting; the public verification page is unchanged.

## §7 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** APR-8 — contract terms and pricing formulas (`docs/forward-queue.md` item 13).
