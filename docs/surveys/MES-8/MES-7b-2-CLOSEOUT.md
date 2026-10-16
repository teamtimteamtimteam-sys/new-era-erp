# MES-7b-2 close-out (2026-10-16) — step 1 of the "MES-7b-2 close-out + MES-8 Step 0" brief

No database change and no code change: the only writes are docs and the files beside this one. Live reads were read-only
(`BEGIN READ ONLY … ROLLBACK`, as `postgres`, `rolbypassrls = true`, base tables and the catalog). The deployed-app page probe (item b) used
throwaway clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes7b2probe`, already registered at `scripts/ephemeral.mjs:250`) — accounts,
roles and grants created and removed by the shared ephemeral plan; read back afterwards (20:10:16 CST): **0 throwaway accounts, 0 probe roles**,
every change-log INSERT matched by a DELETE (roles 5 / 5 · user_roles 5 / 5 · role_permissions 228 / 228). No record that existed before was touched.

**Opening check.** First command **2026-10-16 19:57:20 CST** (`date`). Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`3c281640c70d173db1266d95be62c6b08b449252`. No git command was refused.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 54, in the MES-7b-1 format:
- start **2026-10-16 19:03:57 CST** (measured: `db/migration-windows.tsv`, `2026-10-16-mes7b2-inspections-and-environment.sql`);
- end, lower bound **2026-10-16 19:53:32 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `3c281640 refs/remotes/origin/main@{2026-10-16 19:53:32 +0800}: update by push`; `f30c256d` was never pushed alone — it went out in this same push);
- end, upper bound **2026-10-16 19:57:20 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of Vercel).
- **Window: at least 49 min 35 s, at most 53 min 23 s.**
- **What landed on live inside the window** (`closeout-readings.sql`, 20:10:59 CST, `READ_OWN_EXIT=0`): checklists 0 · items 0 · runs 0 · results 0 ·
  findings 0 · closures 0 · parameters 0 · environmental results 0 · incidents 0 · NCRs 0 · tasks 20; 192 views, **0** (view, role) pairs with a write
  grant. Change log from the window start: only MES-7b-2's own smoke / proof throwaways 19:21:58–19:47:56 (roles 13 / 13 · user_roles 13 / 13 ·
  role_permissions 468 / 468 · employees 3 / 3 · performance_reviews 1 / 1 (+1 update) · contracts 2 / 2 with their term rows · one
  `cod_verification_failures` row in and out), every INSERT matched by a DELETE; **0 rows between the push and this session**.
- **The deployed app is the MES-7b-2 code** (measured, item b): every clone opens `/safety/inspections`, `/safety/inspections/templates/new` and
  `/safety/environment`, and the pending-values page lists V18 and V20 — all exist only from `f30c256d`.

## 2 · F16 exposure (brief item 1.2), read-only, first

**What was measured.** The 45 views that accepted a zero-row write before F16 (33 as anon, 45 as authenticated — MES-7b-2's own before-measurement,
2026-10-16 17:22 CST, its log lines `VW|<view>|<kind>|<role>|<op>|ACCEPTED`, 125 accepted (view, role, op) cells) were walked to their base tables through
`pg_depend` on each view's rewrite rule, recursively through views, keeping `relkind 'r'` (`f16-exposure.sql`, 20:02:24 CST, `READ_OWN_EXIT=0`):
**45 views → 37 base tables** (two views also reach a second table: `employees_masked` → `positions`, `pricing_formula_history_masked` →
`pricing_formulas` — a superset, reported as read, never narrowed). None of the 37 is in `change_log_exclusions()` (8 tables; read at
`db/functions/change_log_exclusions.sql`).

**The date range the change log covers.** `change_log` (base table, `postgres`): **45,139 rows, 2026-09-28 23:58:11 → 2026-10-16 19:47:56 CST**;
`change_log_began_at()` declares the same start. **Nothing before 2026-09-28 23:58:11 can be read** — the write grants are older than that (MES-7b-1
measured them on views created over months), so the part of the exposure before the log began is **unmeasured**, not clean. After 19:03:57 (F16's
commit) no view accepts a write (re-measured by MES-7b-2 at 19:21:55; today's catalog: 0 pairs on 192 views).

**What the change log can and cannot attribute.** It records `actor_kind` (`user` / `no_session`), the account and `db_role` (the `role` setting,
`db/tables/change_log.sql:12-17`). It therefore attributes a write **to a role and an account**. It does **not** record the path: a write through a
SECURITY DEFINER function, a direct REST write and a write through an owner-rights view all land on the base table's trigger with the same
`db_role = authenticated` and the same account. **"Did this write come through a view" cannot be read from the change log** — what can be read is
whether each write's shape (table, operation, changed columns, the other tables its transaction wrote, the account and its time) matches a path the
repo knows. That is the reading below.

**Counts per base table** (`f16-exposure.sql`, TBL lines): 32 of the 37 tables have **0** change-log rows in the whole range. The other five:

| base table (views over it) | rows | authenticated user | anon | no session | how each is explained |
|---|---|---|---|---|---|
| `approval_log` (`approval_log_masked`) | 2 | 2 | 0 | 0 | admin@ (`321f1819…`) deciding two leave requests, 2026-09-29 22:43:20 / 22:43:43: each INSERT is in the same transaction as the `leave_requests` UPDATE (`decided_at, decided_by, status, …`) and, for the first, a `leave_consumption` INSERT — the shape of `decide_leave_request` (`db/functions/decide_leave_request.sql:94,108`) |
| `leave_requests` (`leave_requests_masked`) | 2 | 2 | 0 | 0 | the same two transactions (txid 28608, 28610) |
| `gateway_keys` (`gateway_keys_masked`) | 6 | 6 | 0 | 0 | MES-1's live HTTPS probe (2026-10-06 15:08, `docs/handbacks/MES-1.md:168`) and its later retirement: 3 INSERTs alone in their transaction (`issue_gateway_key`), 1 UPDATE of `revoke_reason, revoked_at, revoked_by` alone (`revoke_gateway_key`), 2 UPDATEs of the same columns together with a `devices` UPDATE (`retire_device`); the three actors are MES-1 throwaway accounts that no longer exist |
| `performance_reviews` (`performance_reviews_masked`) | 555 | 370 | 0 | 185 | every route-smoke run since 2026-09-29: 185 INSERTs by the smoke's throwaway admin (`open_probation_review`, `scripts/smoke-routes.mjs:2265`), 185 UPDATEs of `reviewer_employee_id, updated_at` (`set_review_reviewer`, `:2280`), each in its own transaction; 185 DELETEs with no session (`service_role`, the smoke's cleanup plan, `:2250`); **185 inserted, 185 deleted, 0 still present**; 185 distinct actors, 0 still existing |
| `employees` (`employee_lookup`, `employees_masked`, `handover_people`, `task_assignable_employees`) | 876 | 0 | 0 | 876 | the smoke's throwaway employees (`mkEmp`, service role): **438 INSERTs, 438 later DELETEs, 0 still present, 0 UPDATEs** — one INSERT = DELETE pair set per smoke day, 2026-09-29 … 2026-10-16 |

Across all five: **anon 0 rows**; every no-session row is `service_role` (no `postgres` row on these tables); every authenticated row matches one of the
four function paths above by table, operation, changed columns, transaction shape, account and time. Each of the 1,441 rows is listed with its time,
table, operation, row id, actor kind, role, changed columns and transaction in **`f16-exposure-writes.txt`** (`f16-exposure-writes.sql`), and the ten
non-smoke ones are quoted in the table above (`f16-exposure-detail.sql`, 20:03:37 CST, `READ_OWN_EXIT=0`).

**Verdict: no unexplained write was found** within the change log's range. Two limits stated plainly: the log cannot tell a view-path write from a
function-path write by the same account (the table above matches shapes, not paths), and the exposure before 2026-09-28 23:58:11 has no record at all.
Step 2 is not stopped by this item.

## 3 · Read-only verification

### a · The fixture list in the MES-7b-2 block, item by item

The block's list (MES-7b-2 brief, Verify: "Fixtures must cover every item restated above, including: …"). Fixture 268 =
`db/fixtures/268-an-inspection-is-recorded-once-a-finding-is-followed-to-closure-and-an-exceedance-opens-an-incident.sql`. **Re-run today on a fresh
local rebuild of HEAD's mirrors** (`db/verify_rebuild.py --skip-diff --offline`, `REBUILD_OWN_EXIT=0`): `FX268_OWN_EXIT=0` ("FIXTURE 268 全部通过: REG · F16 ·
TPL · NUM · RUN · IMMUT · FIND · TASK · CORR · DUE · V18 · ENV · V20 · NCR · TRAIL"), `FX263_OWN_EXIT=0`, `FX267_OWN_EXIT=0`; the cut's injection script
`db/scripts/2026-10-16-mes7b2-fixture-injections.py` on a second fresh rebuild: **`INJECTIONS_OWN_EXIT=0 (57 injections on 268 + 2 on 263, 0 wrong)`**.
`check-trail-wording` `WORDING_OWN_EXIT=0`; `TRAIL_WORDING_FAULT=wording-drift-mes7b2` → exit 1, one red line (㉝, 1 place); `wording-part-mes7b2` →
exit 1, one red line (㉝, 10 places). `GATE_VIEWWRITE_FAULT=grant python3 db/gate.py --offline` → **`GATE_FAULT_OWN_EXIT=1`**, "viewwrite rebuild: ✗
pending_values:authenticated:insert" (fixture 268's F16 arm went red on the same injected grant).

| # | Item | Covered by (fixture 268 unless named) |
|---|---|---|
| 1 | F16's gate check and its fault cell | `db/gate.py:695-711` (`viewwrite` on live and rebuild; red if any view is writable; red if fewer than 100 views are seen; a probe view granted INSERT must be named every run, `:495-499`); fault `GATE_VIEWWRITE_FAULT=grant` `:475`, `:696-698` (run today: exit 1); 268 F16 `:167-177` (no view writable by anon / authenticated; census ≥ 100) |
| 2 | INS numbering | NUM `:278-280` (`^INS-<year>-[0-9]{4,}$`, the next one +1) |
| 3 | template items copied into a run and unchanged by a later template edit | RUN `:281-284` (item text copied), `:291-302` (checklist renamed, item 2 reworded, item 3 deleted → the run still reads the three original texts and the old name) |
| 4 | pass, fail with a required note, n/a | RUN `:265-266` (`INSPECTION_FAIL_NOTE_REQUIRED|1`), `:263-264` (anything else refused), `:281-282` (`1:pass,2:fail,3:na`, the note stored) |
| 5 | a submitted run unchanged, and a correcting run citing it with a reason | IMMUT `:304-321` (update / delete refused for staff and owner, direct insert refused); CORR `:412-436` (reason required, run required, unknown run, the corrected run unchanged and naming its correction, twice refused, no new finding on a superseded run) |
| 6 | findings, their closure and reminder | FIND `:323-353` (only on a fail, action and owner required, no default due date, both open findings on `inspection_finding_open`, safety view only, immutable); `:392-410` (closing needs what was done, once only, leaves the reminder, closure immutable) |
| 7 | "Raise a task" creating a personal task, and closing it not closing the finding | TASK `:355-391` (personal task owned by the presser, title with run code and item, linked once; the presser reads it, another does not; closed by its owner → the finding stays open and on the reminder; the tasks table gains no column or trigger) |
| 8 | the inspection NCR source requiring a finding, and fixture 263's accept and refuse arms | REG `:158-161` (CHECK: `inspection` ⇔ a finding); NCR `:580-592` (opening holds the batch, the finding counts it); 263 `:250-273` (refuse: `NCR_INSPECTION_FINDING_REQUIRED` `:254-255`, `…_ONLY_WITH_SOURCE` `:264-265`, `INSPECTION_FINDING_NOT_FOUND` `:266-267`; accept: `:269-273`) |
| 9 | environmental results: the limit copied, exceeds, "not judged", append-only | ENV `:512-523` (no limit → not judged, no incident; within → false; above max → true), `:533-537` (below min → exceeds), `:538-540` (row judgement), `:541-546` (limit and unit copied, not rewritten by a dictionary change), `:547-557` (update / delete / direct insert refused) |
| 10 | an exceedance opening an `emission_exceedance` incident in the same transaction | ENV `:504-511` (refused without the NEA answer or the action — and then no incident either), `:524-532` (one incident, kind, reportable, action, responsible, occurred at, what happened, count +1), `:558-569` (a still-exceeding correction cites the same incident) |
| 11 | V18 and V20 rows | V18 · V20 (empty dictionaries) `:194-201` (one row each, safety view only); V18 `:459-463` (one row per active checklist without a frequency); V20 `:476-478` (one row per active parameter without a limit) |
| 12 | wording arm ㉝ | `scripts/check-trail-wording.mjs:7215-7217` (drift fault), `:7407` (part fault), `:7421-7422` (both must bite) — run today, each red in ㉝ only |
| 13 | change-log exclusions at 8 | REG `:148-154` (`change_log_coverage_gaps()` gaps 0, excluded 8; all eight new tables carry `zzz_change_log`) |

**Nothing on the list is uncovered.**

### b · Usability on the deployed app, as clones of admin, cto, warehouse, cfo and finance

`mes7b2-closeout-pages.mjs` (GET only, `PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-16 ≈ 20:05 CST; clones = exactly each role's live codes: admin 81 ·
cto 39 · warehouse 31 · cfo 34 · finance 43). **20 fetches, all HTTP 200, no application error, no page refused.**

| Page | admin | cto | warehouse | cfo | finance |
|---|---|---|---|---|---|
| `/safety/inspections` | 200 · "Inspections" · **"New checklist" a link** · "No checklist yet." · "No inspection has been recorded." | same | same | 200 · "New checklist" **drawn disabled, `module.safety.edit` named** (×1) · same two empty lines | same as cfo |
| `/safety/inspections/templates/new` | 200 · "New checklist" · checklist form, no gate | same | same | 200 · form drawn, gated by `module.safety.edit` (×1) | same as cfo |
| `/safety/environment` | 200 · "Environment" · notice "No monitored parameter is set up yet (pending value V20)…" · no record form (no active parameter) · no result | same | same | same | same |
| `/settings/pending-values` | 200 · V18 ("Inspection checklists: frequency and items …") and V20 ("Emission limit per monitored parameter …") listed | same | same | same | same |

Live holds no checklist, run, parameter or result, so "Record an inspection", a run page, the findings forms and the environment record form were measured on
a **local rebuild of HEAD's mirrors** seeded with `docs/surveys/MES-7b-1/local-seed.sql` (the real roles' codes as clones) and
`docs/surveys/MES-7b-2/local-seed.sql` (three checklists, INS-2026-0001…0003 with findings, three parameters, four results, INC-2026-0004 from an
exceedance), `next dev` against the harness gateway stub: `mes7b2-closeout-local.mjs` (GET only, `LOCAL_PAGES_EXIT=0`). **35 fetches, all 200, no
application error.**

| Page | admin · cto · warehouse | cfo · finance |
|---|---|---|
| inspection list | 3 checklists, 3 runs · "New checklist" a link | 3 checklists, 3 runs · "New checklist" disabled, `module.safety.edit` named (×1) |
| new checklist | form, no gate | form gated, `module.safety.edit` (×1) |
| checklist page (DISCHARGE) | **"Record an inspection" a link** · checklist form | "Record an inspection" drawn disabled + form gated — `module.safety.edit` (×2) |
| record an inspection (`?template=`) | run form, no gate | run form gated, `module.safety.edit` (×1) |
| inspection run INS-2026-0001 | findings section + record-finding form; warehouse: the NCR control disabled naming `module.quality.edit` (×1) | findings section; correct / finding / close controls gated `module.safety.edit` (×3), NCR control `module.quality.edit` (×1) |
| environment | record form, no gate · results read Exceeds / Within / Not judged · the incident code shown | record form gated `module.safety.edit` (×1) · same judgements and incident |
| pending values | V18 and V20 listed | same |

Recording (checklists, inspections, findings, results) is offered to the three safety editors only and drawn-disabled with its code for cfo and finance —
the brief's item. **Weaker spots recorded, not missing, not stopping:** none found in these pages. **One deviation from the MES-7b-2 brief, recorded and
passed to Tim (not a defect and not part of a / b):** F16 step 3 said "set default privileges so future views get no write grant"; the cut did not
(hand-back §9 decision 1: `ALTER DEFAULT PRIVILEGES` cannot tell a view from a table, and 273 of 303 table mirrors rely on the default write grant). It
substituted a mechanism: the revoke block at `db/views/zzz_function_grants.sql:803-829` runs last in every rebuild and inside **every later migration's
own transaction** (`db/apply_migration.sh:67-74`), plus the gate's `viewwrite` line on both sides. Its residual gap, stated: a view created **outside**
`apply_migration.sh` (an ad-hoc SQL session) keeps the default write grant until the next migration or until the next gate run turns red. MES-8 Step 0
asks Tim to accept or reject the substitution (Q26).

### c · Decisions MES-7b-2 took without asking (`docs/handbacks/MES-7b-2.md` §9, titles only)

1. F16 without `ALTER DEFAULT PRIVILEGES`.
2. `zzz_*` view files now replay last in `db/check_mirrors.py`.
3. V19's supplier wording (W7) changed to "To be confirmed by Tim against the NEA licence."
4. Checklist codes are upper-cased; items are realigned by position on edit; a checklist is never deleted.
5. A run can be corrected once; a superseded run takes no new finding.
6. "Due" counts from the last not-superseded run; never inspected = due at once; no frequency or switched off = never reminds.
7. A finding's task is raised once, owned by the presser, needs `module.safety.view` and a task code.
8. A finding needs an owner (an employee); the due date is optional.
9. The environmental parameter's code is its key, locked once used; limit and basis are paired.
10. An exceedance asks the recorder whether it is NEA-reportable and what was done; the incident occurs at the sampling date's Singapore midnight.
11. A correction that still exceeds reuses the incident.
12. The inspection-source NCR replaced `NCR_SOURCE_RESERVED` with three named refusals.
13. `environmental_parameters` is a runtime-config table whose bootstrap is empty.
14. The findings panel's permission gates stack instead of sitting inline.
15. Fixture 268's assertions are NULL-red (`IS NOT FALSE`).
16. The stale anon-baseline line `processing_run_losses` was removed.

## 4 · Verdict

Item 1.2 found no unexplained write; items a and b show nothing missing and nothing not working. **Step 2 (MES-8 Step 0) goes ahead** (brief item 1.5).
