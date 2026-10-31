# ESG-2 — Step 0 survey (2026-10-31)

HEAD at start `f5ffe87baa979cd264008faaecb601af481ff65a` = origin/main (measured with `git rev-parse` after `git fetch`).

## Part 1 — CONTRACT-ESIGN close-out

| step | reading |
|---|---|
| 1.1 production version | `readings/part1-prod-check.txt`: `/settings/signatories` HTTP 200, h1 "Contract signatories". That route exists only from 06287697 on, so production serves 0628769 / f5ffe87. |
| 1.2 read-only check | one throwaway cfo clone (`esg2probe`): `/contracts` 200, 22.2 s to network idle, no error boundary; `/settings/signatories` 200, 7.1 s, the cfo sees the page as restricted (cfo does not hold `action.manage_signatories`). Nothing pressed or uploaded. `CE_CLOSEOUT_EXIT=0`. DB before/after: select 1 executes in 0.025 / 0.033 ms, median round trip 461 / 409 ms, health db and rest ACTIVE_HEALTHY. |
| readback | `readings/part1-readback.txt` (as `postgres`, counts only): 7 users, all enabled · throwaway users / roles / orphan grants 0 / 0 / 0 · roles held admin,cco,cfo,cto,finance,gm,warehouse · approvals on, finance/cfo/1000 · require_calibrated_since NULL · 2 CODs · cfo holders 1 · 11 roles · reconciliation AP 0.00 / AR 0.00 (read as tim@). |
| 1.3 | `docs/forward-queue.md` 64d-9 marked deployed / not closed; Tim's signing walk is `docs/manual-walk-list.md` §37. |

## Live facts (`readings/step0-live-reads.txt`, as `postgres`, rolbypassrls; all five sources are base tables, relkind `r`)

- incidents 0 (injury 0, days_lost > 0: 0) · training_records 1 ("iras tax training", technical, no expiry date) · electricity bills 0 · attendance periods 0 / lines 0 · employees 7 · positions 6 · departments 1 · leave requests 6.
- So on live every new page reads empty. Any figure (Scope 2 tonnes, LTIFR, coverage) can only be shown on the local rebuild with seeded rows.
- Who holds the codes (live role_permissions; live holders: admin, cco, cfo, cto, finance, gm, warehouse, one each; auditor and operations have no holder):

| code | roles |
|---|---|
| module.safety.view | admin auditor cco cfo cto finance gm operations warehouse |
| module.safety.edit | admin cto warehouse |
| data.view_health | admin cco cfo finance |
| module.hr.view | admin auditor cco cfo cto finance gm |
| module.hr.edit | admin cco finance |
| module.finance.view | admin auditor cco cfo cto finance gm |
| module.processing.view | all nine listed roles (admin auditor cco cfo cto finance gm operations warehouse) |

## Where each figure comes from

**A · Scope 2.** kWh = `electricity_allocations_masked.bill_kwh`, read by `app/safety/energy/page.tsx:55-57`. Reversed bills are dropped (`:58-62`). Bills are already split into whole-month and other bills (`wholeMonths`, `:31-36`). Today there is no factor and no setting (`:10`). New: a factor table with history. `electricity_settings` (`db/tables/electricity_settings.sql`) is a single row with no history, so it is the wrong shape for this.

**B · Safety rates.** Lost-time injuries and days lost come from `incidents.days_lost` (`db/tables/incidents.sql:52`). That column is health data: it is revoked from the column grant (`:96-99`) and readable only through `incidents_masked` (`db/views/incidents_masked.sql:41`, data.view_health or the injured employee). Days lost **cannot be corrected later**: `incident_updates.field` allows only seven fields and days_lost is not one of them (`db/tables/incident_updates.sql:24-25`). Hours worked: `attendance_lines` has **no normal-hours column**. It holds only three overtime columns, unpaid days and active_from/active_to (`db/tables/attendance_lines.sql`). The only schedule fact is `hr_settings.working_days_per_week` (`db/tables/hr_settings.sql:22`), and no hours-per-day exists anywhere. So hours worked must be derived, and that needs one new setting.

**C · Training.** `training_records` (`db/tables/training_records.sql:10-25`). `training_name` is free text and `category` is one of 7 values. There is no catalogue and no "required" anywhere. The expiry window already exists as 90 days, critical at 30 (`db/views/hr_alerts.sql:200-216`; `/hr/training` filter `app/hr/training/page.tsx:80-82`). Reading needs module.hr.view or the employee's own rows (`:35-38`, `:57-59`).

**D · Policies / whistleblowing.** Nothing exists (no table, view, permission or page; `permissions` codes matching policy/whistle: 0). Every new table must be bound to the change log or excluded with a reason (`scripts/check-change-log-coverage.mjs:8-10`). Masked columns need change-log mask rules (`db/gate.py:737-741`), so a report's content has to be masked in change history too.

## Brief claim measured false

- "docs/surveys/SYSTEM-MAP-4/ (the ESG survey: candidates 3-5 and the Scope 2 note)": no such text is in the repo (`git grep -i "candidate 3\|grid emission"` over docs gives only `docs/forward-queue.md:1621` and `docs/system-map.md:207`). The only record of the queued ESG items is forward-queue 64d-8 (line 1621).

## Step 1 — build (Tim's rulings 2026-10-31 08:51 CST; v1.4.86)

| # | step | reading |
|---|---|---|
| 1 | fixture 307 on the local rebuild | `FIXTURE 307 全部通过: P F S H L C T D W`; the same fixture on a pre-change rebuild after applying the migration with `check_function_bodies = on`: passes |
| 2 | fault injections | `readings/fixture-307-injections.txt`: ① readable ignores the CCO flag → `W route 2` red (cco reads the escalated report); ② readable asks the escalated code for unmarked → `W route 1` red (cfo reads, cco does not); mirror replayed → green |
| 3 | mirror vs migration (local) | rebuild of the new mirrors vs the migrated pre-change rebuild: `NO DIFFERENCES` (B1 hits there were only because that apply skipped the grant replay; replaying `zzz_function_grants.sql` → 0) |
| 4 | offline gate | `readings/gate-offline.txt`: `GATE_EXIT=0` (202 s); run 1 (`gate-offline-run1-fixture298.txt`) red on fixture 298's admin shape, fixed |
| 5 | backup | `readings/backup.txt`: `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-31-0951.dump` + 24 change_log chunks (109,630 rows = count), 09:51:56 → 10:17 CST |
| 6 | live dry run | `readings/dry-run.out`: `DRY_OWN_EXIT=0`. Run 1 lost the SSL connection mid-body (`dry-run-run1-connection-lost.out`; no backend left, nothing persisted); run 2 green but its admin readings were void — the holder lookup ran after `SET LOCAL ROLE authenticated` under the cco's claims (`dry-run-run2-admin-harness.out`); harness fixed and a 63-character policy name shortened, run 3 green: grants exactly admin/cco/cfo `action.manage_esg`, cco `data.view_whistleblowing`, cfo `…_escalated`; cfo readable(escalated) true / plain false; cco the reverse; admin neither, and admin reaches the value check (`ESG_STANDARD_HOURS_INVALID`); warehouse `PERMISSION_DENIED|action.manage_esg`; settings 1 row unset, 0 factors, 12 exclusions, 0 coverage gaps; after ROLLBACK 0 new tables, 0 new codes |
| 7 | apply | `readings/apply.txt`: `APPLY_OWN_EXIT=0`; **broken window from 2026-10-31 10:30:03 CST** (`db/migration-windows.tsv`) |
| 8 | types · tsc | `TYPES_OWN_EXIT=0` · `TSC_OWN_EXIT=0` |
| 9 | layout survey | `readings/layout-390.txt` / `layout-1440.txt`: 8 routes (/safety, /safety/energy, /safety/rates, /safety/training, /safety/policies, /safety/whistleblowing, /hr/training/new, /me) — 390 px 8/8 usable, 1440 px 8/8 usable, 0 overflow, 0 clipped tables. Live tables are empty, so this measures the empty states; the /me concern form (the survey session has no employee record) is measured open in the live proof at 390 and 1440 px |
| 10 | build | `readings/build.txt`: `BUILD_EXIT=0` (run 1 red: two `unpaged-ok:` reasons too short) |
| 11 | full gate | `readings/gate-full.txt`: `GATE_EXIT=0`, every verdict ✓ (started 10:41:56) — re-run on the final tree after smoke (step 15) |
| 12 | i18n · swallow | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 13 | smoke | `readings/smoke.txt`: `SMOKE_EXIT=0` — 354 ok, 26 skipped (no data; `/safety/whistleblowing/[id]` among them as registered), 0 failed, `NETRETRY_TOTAL=0`. Run 1 stopped in pre-flight (the new id source needed a sort key). The scratch report lists 6 stale `ZZ-SMOKE-*` rows, 1,400–2,050 h old, 5 still referenced — pre-existing, not touched |
| 14 | live proof | `readings/live-proof.txt`: `ESG2_PROOF_EXIT=0`, 138 PASS, 0 FAIL; seven roles one at a time (admin · cco · cfo · cto · finance · gm · warehouse clones) plus an employee-linked cfo clone (/me) and an admin clone (HR form). One warning: a single 1,520 ms round trip before the employee reader (not an abort). New tables before = after (0 rows each, hours NULL). Registers that cannot be deleted (factor, policies, reports, corrections) were proven on the local rebuild (fixture 307), not on live |
| 15 | readback · COD | `readback-after-smoke.txt` / `readback-after-proof.txt`: 7 users enabled, 0 throwaway users / roles / orphan grants, 11 roles, one cfo holder, approvals finance/cfo/1000, require_calibrated_since NULL, reconciliation AP 0.00 / AR 0.00. `cod-bytes.txt`: both CODs byte-identical to the AGENTS.md baseline |

Gate codes per new page and live holders: /safety/rates `module.safety.view` (all seven; injury figures `data.view_health`: admin, cco, cfo, finance) · /safety/training `module.hr.view` (admin, cco, cfo, cto, finance, gm) · /safety/policies open to every signed-in employee (rows: employees and `action.manage_esg` holders) · /safety/whistleblowing `data.view_whistleblowing` (cco) or `data.view_whistleblowing_escalated` (cfo) · Energy intensity's Scope 2 `module.finance.view` or `module.processing.view` (all seven) · settings and registers `action.manage_esg` (admin, cco, cfo).
