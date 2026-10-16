# MES-7b-1 close-out (2026-10-16) — step 1 of the "MES-7b-1 close-out + MES-7b-2 build" brief

No database change and no code change: the only writes are docs and the files beside this one. Live reads were read-only
(`live-readings.sql`, `BEGIN READ ONLY … ROLLBACK`). The deployed-app page probe (item b) used throwaway clones of real roles
(`mintThrowaway { cloneOf }`, prefix `mes7b1probe`, already registered in `scripts/ephemeral.mjs`) — accounts, roles and grants created and removed by
the shared ephemeral plan; read back afterwards (17:15:56 CST): **0 throwaway accounts, 0 probe roles**, every change-log INSERT matched by a DELETE
(roles 5 / 5 · user_roles 5 / 5 · role_permissions 228 / 228, 17:09:54–17:11:40 CST). No record that existed before was touched.

**Opening check.** First command **2026-10-16 17:06:06 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`c72a86b2403991a62079716d049167663fffd9ca`.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 53, in the MES-7a-2 format:
- start **2026-10-16 15:49:13 CST** (measured: `db/migration-windows.tsv`, `2026-10-16-mes7b1-incidents.sql`);
- end, lower bound **2026-10-16 16:54:08 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `c72a86b2 refs/remotes/origin/main@{2026-10-16 16:54:08 +0800}: update by push`; `08d5fbf8` was never pushed alone — it went out in this same push);
- end, upper bound **2026-10-16 17:06:06 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of Vercel).
- **Window: at least 1 h 04 min 55 s, at most 1 h 16 min 53 s.**
- **What landed on live inside the window** (read 17:15:56 CST as `postgres`, `rolbypassrls = true`, base tables; `live-readings.sql`,
  `READ_OWN_EXIT=0`): incidents 0 · updates 0 · batch links 0 · handover references 0 · NCRs 0 · V19 2, unconfirmed. Change log from the window start:
  only MES-7b-1's own smoke / proof throwaways 16:04:02–16:43:51 (roles · user_roles · role_permissions · employees 6 / 6 · performance_reviews 2 / 2
  (+2 updates) · contracts 4 / 4 with their term rows · one `cod_verification_failures` row in and out), every INSERT matched by a DELETE;
  **0 rows between the push and this session**; then this close-out's own probe (above).
- **The deployed app is the MES-7b-1 code** (measured, item b): every clone opens `/safety/incidents` and `/safety/incidents/new`, the new-handover form
  draws `data-section="handover-incidents"`, and the pending-values page lists V19 — all exist only from `08d5fbf8`.

## 2 · Read-only verification

### a · The fixture list in the MES-7b-1 block, item by item

The block's list ("Fixtures must cover every item restated in section 1, including: …", MES-7b-1 brief, Verify). Fixture 267 =
`db/fixtures/267-an-incident-is-recorded-once-reminds-nea-hides-injuries-and-links-the-batches-a-person-confirms.sql`. **Re-run today on a fresh local
rebuild of HEAD's mirrors** (`db/verify_rebuild.py --skip-diff --offline`, `REBUILD_OWN_EXIT=0`): `FX267_OWN_EXIT=0` ("FIXTURE 267 全部通过: REG · GRANT ·
REFUSE · NUM · MASK · DIRECT · UPDATE · KIND · LINK · NCR · CITE · NEA · V19 · HANDOVER · TRAIL"), `FX263_OWN_EXIT=0`, `FX266_OWN_EXIT=0`; the cut's
injection script `db/scripts/2026-10-16-mes7b1-fixture-injections.py` on a second fresh rebuild: **`INJECTIONS_OWN_EXIT=0` (50 injections on 267, 0 wrong)**.
Build-chain checks run today: `check-enum-mirrors` · `check-i18n` · `check-balance-empty-state` · `check-trail-wording` all `_OWN_EXIT=0`; their faults:
`ENUM_READER_FAULT=old-regex` → check-enum-mirrors exit 2 and check-i18n exit 2; `old-regex-strip` → check-enum-mirrors exit 2 (the truncation cell only);
`CHECK_BALANCE_EMPTY_FAULT=two-sources` → exit 1; `TRAIL_WORDING_FAULT=wording-drift-mes7b1` → ㉜ red (1), `wording-part-mes7b1` → ㉜ red (7).

| # | Item | Covered by (fixture 267 unless named) |
|---|---|---|
| 1 | INC numbering | NUM `:351-359` (`^INC-<year>-[0-9]{4,}$`, the next one +1) |
| 2 | each required field and the future-time refusal | REFUSE `:316-329` (kind · time · what happened · immediate action · responsible · NEA-reportable each by name; `INCIDENT_TIME_IN_FUTURE`); nothing written `:346-347` |
| 3 | device source refused | REFUSE `:330-331` (`INCIDENT_SOURCE_RESERVED|device`) |
| 4 | incident rows never changing and updates appended | DIRECT `:394-405` (insert through function only; update / delete refused for staff **and** owner); UPDATE `:446-447` (the row keeps its text after two corrections), `:454-455` (`INCIDENT_UPDATE_IMMUTABLE`) |
| 5 | kind dictionary with no "other" and the locked code | REG `:174-181` (seven kinds; inserting `other` hits the CHECK); KIND `:459-474` (`INCIDENT_KIND_CODE_LOCKED|injury|1`, delete refused, rename allowed, a kind used only by a correction is locked too) |
| 6 | injury columns masked for an editor without `data.view_health`, visible to the injured employee | REG `:193-199` (five mask rules, out of the column grant); MASK `:361-382` (editor reads `injury_visible = false` and NULLs, base column → permission denied; health holder reads it; injured employee with no safety code reads their own and not another's); trail `:384-390` |
| 7 | both batch suggestions at the moment | LINK `:488-499` (location: the stock at the bay at that moment, not another bay, not stock that arrived later; machine: input and output of the run spanning the moment, not an earlier run) |
| 8 | confirmation, pick by code | LINK `:503-512` (confirm location / machine suggestions; not-suggested refused; `picked`; twice refused) |
| 9 | unlink requiring a reason | LINK `:518-532` (`INCIDENT_UNLINK_REASON_REQUIRED`, once only, no rewrite, no delete) |
| 10 | no safety state set | LINK `:480-481`, `:533-535` (md5 of safety states and movements unchanged) |
| 11 | the incident NCR source opening a hold | NCR `:542-559` (not-linked batch refused; link alone holds nothing `:550-551`; NCR on a linked batch → `batch_quality_hold` row, `ncr_rows.holding`) |
| 12 | downtime citation refused for another machine | CITE `:563-564` (`INCIDENT_DOWNTIME_OTHER_MACHINE|FX267-M2`), `:565-568`; MTBF untouched `:571-574` |
| 13 | the NEA reminders | NEA `:600-604` (both, safety view only), `:616-626` (notified → only the report reminder; report → none), `:628-634` (corrected to not reportable → none) |
| 14 | the working-day deadline with and without the holiday calendar | NEA `:579-590` (`business_days_after`: no calendar → NULL; weekend + Monday holiday → Wednesday; independent count `pg_temp.f267_nth_workday` `:138-146`); `:605-614` (incident deadline = 2nd working day, `cannot_compute` with the calendar inactive) |
| 15 | V19 shown as unconfirmed | REG `:210-213` (2, unconfirmed, source `:2402`); NEA `:606-608` (`deadline_confirmed` false); V19 `:638-666` (on the pending list, edit code, confirm → off the list, changed number → unconfirmed again, empty → `not_set`) |
| 16 | handover references | HANDOVER `:671-684` (unknown incident refused; two refs stored; both readers see them; direct insert denied) |
| 17 | the safety grants and the action-implies-view check | GRANT `:230-251` (every processing-view role holds safety view; edit implies view; bootstrap edit = admin, warehouse; warehouse lacks health; `set_role_permissions` → `EDIT_REQUIRES_VIEW|safety`) |
| 18 | wording arm ㉜ | `scripts/check-trail-wording.mjs:7058-7208` — drift fault `wording-drift-mes7b1` `:7064` with its bite check `:7207`, part fault `partFault('mes7b1', …)` `:7193` / `partFaultBit` `:7208`, ≥ 2 part sentences `:7205` |
| 19 | the F12 note | REG `:214-217` (rebuild side: the new sentence, the old "【不按批次追溯】" absent); live: read back today — the mirror's sentence (`NOTE|spare_part|…`, `live-readings.sql`) |
| 20 | F13's four fault cells and coverage check | `scripts/lib/sql-in-list.mjs:156-165` (`selfCells`: a `)` in a comment must not truncate; `'ghost'` in a comment must not add), run by `check-enum-mirrors.mjs:84-91` and `check-i18n.mjs:36-39` (two cells × two checks); coverage = independent count `countLiteralsOutsideComments` (`check-enum-mirrors.mjs:66-68`, `check-i18n.mjs:211`) |
| 21 | F14's empty-state rule | `lib/balanceEmptyState.ts:8`; `scripts/check-balance-empty-state.mjs:21-31` (8-row truth table; fault `two-sources`) |
| 22 | change-log exclusions at 8 | REG `:200-206` (`change_log_coverage_gaps()` gaps 0, excluded 8; six new tables carry `zzz_change_log`) |
| 23 | after every finance-touching case, AP list = ledger and 0.00 unexplained | `pg_temp.f267_recon` `:103-118` (both list sides 0.00; inventory control 1200 reconciled), called after the receipts `:297` and at the end `:695` |

**Nothing on the list is uncovered.**

### b · Usability on the deployed app, as clones of admin, cto, warehouse, cfo and finance

`mes7b1-closeout-pages.mjs` (GET only, `PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-16 17:09:49–17:11:43 CST; clones = exactly each role's live codes:
admin 81 · cto 39 · warehouse 31 · cfo 34 · finance 43). **20 fetches, all HTTP 200, no application error, no page refused.**

| Page | admin | cto | warehouse | cfo | finance |
|---|---|---|---|---|---|
| `/safety/incidents` | 200 · "Record an incident" a link · V19 panel · "No incident has been recorded." | same | same | 200 · record **disabled, `module.safety.edit` named** (×2) · V19 panel · empty line | same as cfo |
| `/safety/incidents/new` | 200 · form with the injury section, no gate | same | same | 200 · form drawn, gated by `module.safety.edit` (×1) | same as cfo |
| `/operation/handovers/new` | 200 · section "Incidents to pass on" with its hint · "No incident cited." (live has no incident) | same | same | same | same |
| `/settings/pending-values` | 200 · V19 section, its text says "unconfirmed" | same | same | same | same |

Live holds no incident, so the incident page, the "Restricted" reading and a handover citing incidents were measured on a **local rebuild of HEAD's
mirrors** seeded with `docs/surveys/MES-7b-1/local-seed.sql` (the seven real roles' codes as clones; three incidents — INC-2026-0001 an injury,
INC-2026-0002 a fire, INC-2026-0003 a near miss; one handover citing two), `next dev` against the harness gateway stub: `mes7b1-closeout-local.mjs`
(GET only, `LOCAL_PAGES_EXIT=0`). **35 fetches, all 200, no application error.**

| Page | admin | cto | warehouse | cfo | finance |
|---|---|---|---|---|---|
| incident list | 3 rows · record link | 3 · record link | 3 · record link | 3 · record disabled (`module.safety.edit`) | same as cfo |
| injury incident INC-2026-0001 | injury text shown, 0 × Restricted | **5 × "Restricted"** + "injury details are kept for people allowed to see health information…", no injury text | **5 × "Restricted"** + the same line; NCR control disabled naming `module.quality.edit` | injury text shown; edit controls disabled naming `module.safety.edit` (×4) | same as cfo |
| new handover form | 3 incidents to tick | 3 | 3 | 3 | 3 |
| handover page | cites its incidents (INC codes shown) | same | same | same | same |
| pending values | V19, "unconfirmed" | same | same | same | same |

cto and warehouse are the two safety editors without `data.view_health`; both read "Restricted" on the injury incident — the brief's item.
**Weaker spot, recorded, not missing, not stopping:** **W7** — the V19 line on the pending-values page opens "Confirmed by Tim against the NEA licence."
(the "who supplies it" slot, where every other value reads "Supplied by …"), then says "unconfirmed". Read alone, the first sentence sounds like a
fact. Recommended: "To be confirmed by Tim against the NEA licence." — a wording change only.

### c · Decisions MES-7b-1 took without asking (`docs/handbacks/MES-7b-1.md` §8, titles only)

1. Safety is a 10th top-level module (after Operation), with its own codes.
2. Injury fields cannot be corrected.
3. Closing does not clear the NEA reminders.
4. F12 uses the mirror's full sentence.
5. The injured employee's own page (a self-only view without a safety code).
6. `incident_report_due.item_date` falls back to the incident date.
7. The seeds of `incident_kinds` and `safety_settings` are not change-logged.
8. `shift_handover_incident_refs` is written only through `submit_shift_handover`.
9. `incident_people` view for the employee pickers.
10. New views revoke the platform's default write grants.
11. A superseded run event cannot be cited.
12. The deadline counts from the incident date in Singapore; NULL when a calendar year it crosses has no holidays.
13. Location suggestions use net stock at that location up to the incident moment.
14. F13 scope: four readers switched, the Python reader registered.
15. The local harness for the layout survey and F14.
16. The NCR source `inspection` is left as it was (7b-2's question).
17. The dry-run defect: the F12 extractor fix touched only the builder.

## 3 · Verdict

Items a and b show nothing missing and nothing not working (one wording weakness, W7). **Step 2 (MES-7b-2) goes ahead** (brief item 1.4).
