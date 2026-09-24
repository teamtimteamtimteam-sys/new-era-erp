# PAYROLL-APR-1 — payroll posting and its reversal wait for the CFO (2026-09-24)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `a243831eedb3457c8b49fb073b10fa7676029144`
(ROLE-1 Batch 2b). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with
its identity. The matrix line is `docs/role-matrix.md` §5; the approvals effects are `docs/approvals.md` §3l.

---

## §W · ROLE-1 Batch 2b's broken window — closed with bounds, labelled by kind

Tim confirmed the Batch 2b deploy on 2026-09-24, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-24 22:07:50 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 22:39:27 | **measured**: the push moved `origin/main` → `a243831e` (`git reflog show refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 23:01:11 | **derived**: the first live read of this session, database clock `now()` as `postgres`, taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 31 min 37 s, at most 53 min 21 s.** Also written into `docs/handbacks/ROLE-1.md` § Batch 2b §5.

---

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (read as `postgres`, `rolbypassrls = t`, base tables, `relkind = 'r'` checked; probes in rolled-back
transactions):
1. **The CFO's own pay line decides the cut's shape.** As tim@, `forbid_self_approval(chooer, <EMP-2026-0002>, 'payroll_period')`
   → `SELF_APPROVAL_FORBIDDEN|subject`; with subject `NULL` it passes; with raiser `admin@` → `|raiser`;
   `self_approval_exception('payroll_period', …)` → `false`. Tim (EMP-2026-0002) is on the register, so judged as a subject
   **every** period would stall: level 2 has one real holder (tim@) and R2 excludes payroll.
2. **"Nothing posts until approval" was false before this cut.** As chooer@, a direct `UPDATE payroll_periods SET status` →
   1 row; a direct edit of a posted period's line → 1 row (both rolled back). `payroll_periods` had no status guard, and
   `reverse_journal_entry` still reversed payroll entries.
3. **Nothing on live could be posted anyway:** 0 attendance periods; posting already refuses `PAYROLL_ATTENDANCE_NOT_COMPLETE`.
   Live payroll = one period, PAY-2026-0001 (July, posted, 1 line — Choo Er, gross 5,000 — line, CPF and deductions all paid).
4. **Test-data residue:** 2300 reads +4,677.00 and 2400 +156.00 (debit − credit). JE-2026-0017 predates FIN-4 and credited
   the bank directly; the later payment entries debited the payables again. Recorded in `docs/known-wrong-until-cutover.md`.

**Tim accepted all nine recommendations (Q1–Q9):**
- **Q1 (A)** — a payroll period is a **company document**: the subject check applies to nobody; the raiser check still applies,
  judged by person. **Tim's reasoning, recorded:** the CFO cannot change his own salary at this step — a monthly salary changes
  only through a performance review (Tim's own is approved by cco) or a salary-change request — and the control that matters is
  that the preparer is not the approver. The screen says "this period includes your own pay line"; the `approval_log` note
  records it; no `self_decided` flag.
- **Q2** new table `payroll_requests` (kind `post` / `reversal`); `payroll_periods.status` stays `draft` / `posted`;
  `approval_log` gains `payroll_request`.
- **Q3** finance executes Post / Unpost; both refuse by name without an approved request for that period and kind.
- **Q4** while a request is open: saving refused, that month's attendance cannot be reopened, the stored figures are
  re-checked at approve and at execute (`PAYROLL_CHANGED_SINCE_REQUEST`).
- **Q5** three side doors closed; `PAYROLL-PAYMENT-NO-REVERSAL-PATH` registered.
- **Q6** the three payment functions refuse while a reversal request is open.
- **Q7** the PAY-REQ-1 rules, including the dry run before submit and approve.
- **Q8** `require_approver_for(2)`, no threshold; gate `{module.hr.view, data.view_pay}`; `gross_total` in base currency as the
  logged amount; `blocks_disable = true`, `fixed_level = 2`; **no new codes**.
- **Q9** controls on the period page, en and zh.
- Standing: **no new permission code**, so the "grant every new code to admin" ruling has nothing to grant this cut;
  `module.tasks.view_all` not added to admin.

---

## §1 · What shipped

**Migration** `db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql`, assembled from the mirrors by
`db/scripts/build_payrollapr1_migration.py`. One transaction; its self-proof asserts, in the same transaction: approvals still
ON; pending documents unchanged; `approval_log`, `journal_entries`, payroll periods and lines unchanged; **grants unchanged**
(no code added or removed); `payroll_requests` empty; the old `unpost_payroll_period(uuid, text)` gone; both guard triggers
present; the new chain has exactly one row (level 2) and **a real decider on live** (`approval_deciders` → tim@); every pending
document still has a decider who is not its own party.

| piece | what |
|---|---|
| `payroll_requests` (new table) | kind `post` / `reversal`; `submitted → approved → executed`, `rejected`, `withdrawn`; `snapshot` (the approved figures); `label` = period code · kind · #n (no document number, not in `document_types`); one open request per period (unique index); read on `module.hr.view`; **no write policy** |
| `submit_payroll_request` · `withdraw_payroll_request` | finance (`module.hr.edit`); submit dry-runs the engine; born `approved` + `auto_approved` when approvals are off |
| `decide_payroll_request` | gate `module.hr.view` + `data.view_pay`; `forbid_self_approval(created_by, NULL, 'payroll_request')`; `require_approver_for(2)`; reject needs a reason; approve re-checks the snapshot and dry-runs; the log note names the approver's own line |
| `post_payroll_period` · `unpost_payroll_period(uuid)` | now doors: an approved request for that period and kind, or `PAYROLL_NEEDS_APPROVED_REQUEST`; snapshot re-checked; request marked `executed` with its journal entry |
| `post_payroll_period_internal` · `unpost_payroll_period_internal` · `payroll_request_dry_run` · `payroll_period_fingerprint` | the engine and its helpers; EXECUTE revoked from `authenticated` |
| `payroll_period_frozen` | `posted` / `requested` / `open` for the two INVOKER guards; DEFINER so an `hr.edit` holder without `hr.view` cannot read "no request" by not seeing it; allowlisted in both B2 lists (the `period_close_floor` precedent) |
| `guard_payroll_period_direct_write` · `guard_payroll_line_direct_write` | the side doors (Q5) |
| `upsert_payroll_period` · `reopen_attendance_period` | refuse while a request is open (Q4) |
| `pay_payroll_lines` · `pay_payroll_cpf` · `pay_payroll_deductions` | refuse while a reversal request is open (Q6) |
| `reverse_journal_entry` | refuses a payroll **posting** entry and its reversal; payroll **payment** entries still pass (known issue registered) |
| engine | `approval_chain_gates` row · `approval_pending_documents` arm · `approval_log` CHECK + read branch · `record_approval_decision` branch · `operations_now` arm `payroll_request_pending` |

**Screens (en + zh):**
- `/hr/payroll/[id]`: one **Approval** panel instead of the old Post / Unpost buttons. It offers, depending on state: request posting (with the posting preview),
  request unposting (reason), approve / reject (with "this period includes your own pay line" when the viewer has a line),
  execute Post / Unpost, withdraw; earlier requests listed. Controls stay visible and disabled with the code they need
  (`module.hr.edit` for raising / executing / withdrawing, `data.view_pay` for deciding). Who is level 2 and who raised it is
  left to the database, as on payment requests. While a request is open, **Edit** is visible, disabled, with the reason.
- The posting preview's fifth line now says **2300 Net Salaries Payable** — it used to say the bank account, which posting has
  not touched since FIN-4.
- `/hr/payroll`: a **request** column (kind · status of the open request).
- Dashboard reminder `payroll_request_pending` (`data.view_pay`) → the period page.

**Fixtures:** new **218** (arms A–L). Updated because a new chain now needs a level-2 holder of `module.hr.view` +
`data.view_pay` before approvals can be switched on: 35 · 52 · 127 · 151 · 202 · 203 · 204 · 205 · 206 · 210 · 211
(206 gives the codes to a second holder, so its read-only reader arm still measures what it says; 205's own-document-gap count
4 → 5). 141 calls the engine (`*_internal`) for its attendance arm; 214 names `unpost_payroll_period_internal(uuid,text)`;
111 lists the 37th reminder arm.

---

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (detached, run 3) | **`GATE_EXIT=0`**, pre-migration phase 51 s. Runs 1–2 were red and are the reason 11 fixtures changed: run 1 `GATE_EXIT=4` (12 fixtures: 11 × `APPROVALS_CHAIN_HAS_NO_APPROVER\|decide_payroll_request`, and 218 C2 hit a masked column); run 2 `GATE_EXIT=4` (205's count 4 → 5, 206's reader saw more once its role held `hr.view`, 218's J arm rejected a request raised by the approver's own second account — correctly refused) |
| backup (`db/run_detached.sh`, token BACKUP) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-24-2347.dump`, 4.6 MB, TOC 6,148 (previous 6,138, floor 5,524) |
| `db/apply_migration.sh`, attempt 1 | **`APPLY_OWN_EXIT=3`, nothing committed.** The builder had cut the `approval_log` read policy at a `;` inside a `--` comment, so psql never saw the statement end and swallowed the rest of the file; the error surfaced at the grants replay (`function public.post_payroll_period_internal(uuid) does not exist`). Read back as `postgres` at 00:09:02: `payroll_requests` absent, `unpost_payroll_period(uuid,text)` present — the transaction rolled back; `db/migration-windows.tsv` got no line. Fixed the builder's statement extraction (skips `--` comments and quoted strings); dry-ran the rebuilt file on live with `COMMIT` → `ROLLBACK`: `DRY_OWN_EXIT=0`, self-proof notices printed, every pending document with a decider |
| `db/apply_migration.sh`, attempt 2 | **`APPLY_OWN_EXIT=0`**. Pre-flight: 22 CREATE FUNCTION (10 replace · 12 new), 7 account codes all `is_system`, no columns on a masked table. **Window start 2026-09-25 00:12:32 CST** (the script's "applied at" line reads 00:11:45) |
| `npm run types:gen` (after `NOTIFY pgrst, 'reload schema'` — the migration dropped a signature) | `TYPES_OWN_EXIT=0`; `unpost_payroll_period` is `{ p_id }` |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` on the third run. Run 1 → 1: the new list column pinned `text-sm` on a cell (`check-component-library`); run 2 → 2: `check-document-registry`'s pinned table count (227 → 228, the new table has no `code` column). Re-run after the `JE_REVERSE_USE_SOURCE_PATH` copy change (§5): `BUILD_OWN_EXIT=0`, `I18N_OWN_EXIT=0` |
| `db/gate.py` full (detached) | **`GATE_EXIT=0`**, 733 s wall clock: rebuildable ✓ · mirrors vs live ✓ (`NO DIFFERENCES`) · fixtures ✓ (**221 passed, 0 failed**, 218 included) · anon surface ✓ (live ⊆ baseline, 327 rows); B2 allowlist 9 (adds `payroll_period_frozen`) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` — 177 dynamic prefixes, all enumerable (the two new ones read `payroll_requests`' CHECKs) |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, started 00:30:13) | **`SMOKE_EXIT=0`**: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 813.6 s total, median 3,230 ms; disposable session on the 53-code probe role. **Clean-up, read at 00:48:01 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` / `fx%` roles **0** · orphan grants **0** · `ZZ-SMOKE-%` employees **0**; `.ephemeral/` empty; no smoke or `next dev` process from this repo left |

## §3 · Live proof

**Script:** `db/scripts/2026-09-24-payrollapr1-live-proof.sql`. One transaction, `ROLLBACK`, run as `postgres`
(`rolbypassrls = t`); each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result: `PROOF_OWN_EXIT=0`, 27 of 27 cells**, finished 00:48:22 CST (inside the window, after the smoke).

| account | cell | result |
|---|---|---|
| chooer@ | unpost PAY-2026-0001 with no request | `PAYROLL_NEEDS_APPROVED_REQUEST\|PAY-2026-0001\|reversal` |
| chooer@ | request unposting PAY-2026-0001 | the engine's own words at submit: `PAYROLL_LINES_PAID\|PAY-2026-0001`; no request left |
| chooer@ | direct UPDATE of a posted period's status · direct INSERT born posted | `PAYROLL_STATUS_THROUGH_FUNCTION_ONLY` ×2 |
| chooer@ | direct UPDATE of a posted period's line | `PAYROLL_LINES_FROZEN\|PAY-2026-0001\|posted` |
| chooer@ | `reverse_journal_entry` on JE-2026-0017 (the July posting) | `JE_REVERSE_USE_SOURCE_PATH\|JE-2026-0017\|payroll` |
| chooer@ | set-up: August attendance opened, recorded, completed (3 lines); PAY-2026-0002 drafted — Choo Er 5,000 + **Tim 9,000** | passes (rolled back) |
| chooer@ | post August with no request | `PAYROLL_NEEDS_APPROVED_REQUEST\|PAY-2026-0002\|post` |
| chooer@ | request posting August | `submitted` (PAY-2026-0002 · post #1); ledger untouched; `approval_log` submitted, level 2, **14,000.00** |
| postgres | `approval_deciders` for that request | **tim@ only** |
| chooer@ | save August · reopen August attendance · direct line edit, while it waits | `PAYROLL_REQUEST_OPEN` · `ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST\|ATT-2026-08\|PAY-2026-0002` · `PAYROLL_LINES_FROZEN\|…\|requested` |
| chooer@ · admin@ · sandra@ · vince@ | approve | `SELF_APPROVAL_FORBIDDEN\|raiser` · `APPROVAL_NOT_AUTHORISED\|2\|cfo` ×2 · `PERMISSION_DENIED\|data.view_pay` |
| tim@ | execute the posting · reject without a reason | `PERMISSION_DENIED\|module.hr.edit` · `PAYROLL_REQUEST_REJECT_REASON_REQUIRED` |
| tim@ | ★ **approve a period that includes his own line (Q1 (A))** | approved; note `本期含审批人自己的工资行 · this period includes the approver's own pay line: EMP-2026-0002`; **`self_decided = false`**; ledger untouched |
| chooer@ | execute the posting | posted, **JE-2026-0080**; request `executed`; `journal_entries` 82 → 83 inside the proof |
| chooer@ | request unposting; pay lines / remit CPF while it waits | `submitted`; `PAYROLL_REVERSAL_REQUESTED` ×2 |
| tim@ · chooer@ | approve the unposting · execute it | passes; period back to draft, entry reversed |
| tim@ | approve a request raised from **admin@ (the same person)** | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| admin@ | switch approvals off while that request waits | `APPROVALS_CANNOT_DISABLE_WITH_PENDING\|1\|PAY-2026-0002 · post #2` |

Inside the proof: `journal_entries` 84 (before 82), `payroll_requests` 3, `approval_log` +5 — **all rolled back**; read back
afterwards (below): 82 · 0 · 14. **What this proof is and is not:** refusals and one full lifecycle, run as the real accounts
inside a transaction that was rolled back. **No human walk has happened** — per the standing ruling, the whole chain is
walked once after APR-6 (`docs/approvals.md` §3f).

### Before / after

**Script:** `db/scripts/2026-09-24-payrollapr1-readings.sql`, which states the identity for every part.
**Timing:** before at 23:43:15 CST (2026-09-24); after at 00:48:37 CST (2026-09-25). The two outputs are identical except the
two `payroll_requests` lines.

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs · payment requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 | **the same** |
| `payroll_requests` rows | postgres · base | (table absent) | **0 — nothing pending on live** |
| `approval_log` rows · `journal_entries` · payroll entries | postgres · base | 14 · 82 · 4 | **14 · 82 · 4** |
| payroll periods · attendance periods | postgres · base | PAY-2026-0001 posted, 1 line paid · 0 | **the same** |
| account 1100 · 2000 · 2200 · 2300 · 2400 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · −376,404.42 · −1,597.47 · 4,677.00 · 156.00 | **the same** (2300 / 2400: test-data residue, `docs/known-wrong-until-cutover.md`) |
| codes per role (n · md5 of the sorted list): admin · auditor · cco · cfo · cto · employee · finance · gm · hr · operations · procurement · sales · warehouse | postgres · base `role_permissions` | 52 · 19 · 36 · 29 · 31 · 0 · 34 · 20 · 7 · 15 · 15 · 16 · 14 | **the same, every md5 identical** (full lists in the script output) |
| unrevoked grants | postgres · base `user_roles` | admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **the same** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | **16 · 416,988.32** |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | **10 · 57,545.87** |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 52 · 34 · 14 · 31 · 36 · 29 · 20 | **the same, every md5 identical** |

**Pending documents and their deciders** (the migration's own proof, by person): CLM-2026-0004 → tim@ · LV-2026-0001 / 0003 →
admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · ST-2026-0082…0086 → chooer@, fusheng@, phua@, sandra@.
**No pending document is left without a decider, and nothing new is pending on live.**

## §4 · What each person can no longer do

- **Choo Er (finance):** can no longer post or unpost payroll in one step — she requests, and posts / unposts only after the
  CFO approves. She cannot approve her own request, write a period's status or a posted / waiting period's lines directly,
  reverse a payroll posting entry from the journal screen, save a period or reopen that month's attendance while its request
  waits, or pay salaries / CPF / deductions while an unposting request waits.
- **Tim as tim@:** gains approve / reject on payroll requests, including periods that contain his own line (said, not flagged).
  Cannot execute (no `hr.edit`), and cannot approve a request raised from admin@.
- **Tim as admin@:** holds `hr.edit`, so can raise and execute like finance, but cannot approve (not `cfo`); a request raised
  here can only be approved by the CFO — who is the same person — so **it waits for ever**: the standing rule that admin@ does
  not raise business documents applies.
- **Sandra, Phua, Fu Sheng, Vince:** no change (none holds `hr.edit`). Sandra holds `data.view_pay`, so she sees the reminder;
  she cannot decide.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 00:12:32 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at"
line reads 00:11:45). The failed attempt 1 at 00:08:14 committed nothing and opened no window. ~~**End: PENDING — Tim reads it
from Vercel.**~~ **Closed with bounds (ROLE-1 Batch 4a, 2026-09-25; Tim confirmed the deploy before that session began).** The end lies
**between 00:51:49 CST** (*measured*: `origin/main` → `5322fe4d` in git's remote-ref log) **and 01:14:12 CST** (*derived*: the first
live read of the Batch 4a session, database clock `now()` as `postgres` — a relayed confirmation, not a measurement of Vercel).
So the window lasted **between 39 min 17 s and 61 min 40 s**. These are bounds, not a measurement.

What the old app does against the new database (approvals ON):
- **Payroll cannot be posted or unposted at all.** The old period page has only Post / Unpost buttons and no way to raise a
  request. Post → `PAYROLL_NEEDS_APPROVED_REQUEST`, which the old HR error mapper does not know, so it shows the generic
  fallback sentence with a short code. Unpost → the old app calls `unpost_payroll_period(p_id, p_reason)`, a signature that no
  longer exists, so PostgREST refuses and the same generic fallback appears. **On live nothing is affected in practice:**
  the only period is posted and fully paid (unposting it is refused anyway), and no new period can be posted without an
  attendance sheet (0 exist).
- Reversing JE-2026-0017 from the old journal screen is refused by name (`JE_REVERSE_USE_SOURCE_PATH`); the old copy for that
  code names only payments, transfers and WHT remittances, so it points at the wrong path. **The deployed copy (en + zh) adds
  the payroll posting and "Request unposting" on the payroll period** — found while writing this section.
- `/settings/approvals` lists a fifth chain (`payroll_request`) whose name key the old app does not have — the chain line may
  show a raw key until the deploy.
- **Unaffected:** saving draft periods, attendance, every payment path, every other approval chain, the dashboard (0 payroll
  requests, so the new reminder arm is empty).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
Next cut: **ROLE-1 Batch 4 with receipt-pricing approval** (`docs/forward-queue.md`).
