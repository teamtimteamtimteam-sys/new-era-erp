# GOLIVE-1 — go-live readiness rows 1 · 2 · 4 · 5 · 6 · 11 · 12 (v1.4.82, 2026-10-29)

Brief: "GOLIVE-1 — go-live readiness, permissions and data safety: rows 1, 2, 4, 5, 6, 11, 12; close rows 3 and 7 as superseded (close-out of
COD-READERS first)". Started from `2bb34df2d0e54b235a299ee4a53f2a8a62c5d599`. Tim's rulings on Step 0 (Q1–Q9, 2026-10-29, received 17:02 CST) are
recorded verbatim at the end of this file. One migration: `db/migrations/2026-10-29-golive-1.sql` (built from the mirrors by
`db/scripts/build_golive1_migration.py`).

**Identity of every reading:** database reads were row counts and digests as `postgres` (`rolbypassrls`) on base tables; the dry run read as the
real cfo (tim@), cco, warehouse and finance accounts and as a session with no role, inside one rolled-back transaction; the reconciliation line as
tim@ (rolled back); COD bytes through the Storage API (list + GET). Pages were read in a real browser through throwaway accounts made by the shared
helper (`scripts/ephemeral.mjs`, prefixes `codrprobe` / `golive1probe` / `survey` / `smoke`), one reader at a time; nothing was pressed and no form
was sent. **No sub-agent was started in this cut.**

## Part 1 — close-out of COD-READERS

| step | reading |
|---|---|
| 1.1 / 1.2 | `db/scripts/2026-10-29-cod-readers-closeout-prod-check.mjs` → **`CODR_CLOSEOUT_EXIT=0`, 4/4** (`readings/part1-prod-check.txt`, 16:22 CST): one throwaway cfo clone on production — the bar is ten buttons with Logistics right after Sales (⇒ production serves bd127ff / 2bb34df); Safety › Certificates of destruction 3 rows (= database); COD-2026-0001 PDF 34,701 bytes, sha256 identical to the AGENTS.md baseline; the batch page shows the reader's panel, no Issue / Void control. Nothing pressed (menus not opened). |
| read-back | `readings/part1-readback.txt`: 7 users / 7 enabled, 0 throwaway users / roles / orphan grants, exactly one cfo holder, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, reconciliation AP 0.00 · AR 0.00 |
| 1.3 | 64d-5 marked closed in `docs/forward-queue.md`: confirmed 16:13 CST (Tim, relayed), broken window 13:39:08 → 16:13 CST ≈ 2 h 34 min (end point relayed, not measured) |

## What each row did

| row | ruling | what changed | proof |
|---|---|---|---|
| 1 | d2 #2 · Q6 | `action.metal_prices` joins the read policies of `metal_prices`, `index_market_calendar` and `pricing_settings` | fixture 299 (with an injection that restores the old policy) · live proof M |
| 2 | d2 #6 · Q1 | **live was already done** by COD-2 (2026-09-08): default privileges of `postgres` in `public` without `anon`, both armed views revoked. This cut: `db/platform-prelude.sql` §6 runs **after** the replay (verify_rebuild) so a rebuild / fresh install ends with the same default privileges; `docs/fresh-install-checklist.md` step 2c; `db/gate.py` `defacl` line (rebuild side offline, both sides in the full gate); `db/anon-grants-baseline.tsv` = the live set exactly | gate `defacl` ✓; injection `GATE_DEFACL_FAULT=grant` → red, names `r:anon=r/postgres` (`readings/gate-offline-defacl-injection.txt`) |
| 4 | d2 #14 · Q7 | `requeue_supplier_on_identity_change` (BEFORE UPDATE, `trg_suppliers_zz_…`): approved / active / suspended + a change of legal name, tax number or type → `pending_review`, stamp cleared; the status-history trigger now fires on any UPDATE that changes the status; the edit form warns before saving | fixture 300 · dry run Q7 (SUP-2026-0003 → pending_review, one history row, rolled back) · live proof S |
| 5 | d2 #27 · Q2–Q5 | hr · procurement · sales deleted (0 holders incl. revoked, asserted in the migration); auditor 22 → 25 codes; employee description rewritten; bootstrap = live's eleven roles (`db/seeds/eleven-roles-2026-10-29.sql`) | fixture 298 (rebuild = snapshot, injection) · live fixture 298 (live = snapshot) |
| 6 | d2 #30 | `container_overview` predicate = `module.logistics.view` alone; `/logistics` checks the same code | fixture 301 (injection) · live proof C |
| 11 | TE-2b Q5 · Q8 | `save_employee` leaves work_email · work_phone · identity_no · work_pass_no untouched for a writer who cannot see them (not self); the edit page draws 「受限」 and sends nothing | fixture 302 (injection) · live proof E |
| 12 | TE-3c Q3 · Q9 | column-level masking: `sales_settlements` six money columns (`data.view_prices`); contract-term prices by contract side (`contract_terms_price_visible`); five `*_masked` views; change-log rules +10 (`contract_price`); `list_totals_settlements` reads the masked view; `/contracts` and the contract page draw 「受限」, a row with a hidden price cannot be edited, exports write Restricted | fixture 303 (injection) · live proof K |
| 3 · 7 | Tim 2026-10-29 | closed as superseded by SYSTEM-MAP-1; no code | — |

## Roles before and after (live, `postgres` on base tables; holders / codes)

| | before | after |
|---|---|---|
| admin | 1 / 87 | 1 / 87 |
| auditor | 0 / 22 | 0 / **25** |
| cco | 1 / 51 | 1 / 51 |
| cfo | 1 / 37 | 1 / 37 |
| cto | 1 / 42 | 1 / 42 |
| employee | 0 / 0 | 0 / 0 (description rewritten) |
| finance | 1 / 44 | 1 / 44 |
| floor_display | 0 / 1 | 0 / 1 |
| gm | 1 / 24 | 1 / 24 |
| hr | 0 / 8 | **deleted** |
| operations | 0 / 16 (inactive, soft-deleted 2026-09-10) | 0 / 16 (unchanged — Q4) |
| procurement | 0 / 16 | **deleted** |
| sales | 0 / 17 | **deleted** |
| warehouse | 1 / 32 | 1 / 32 |

14 role rows → 11 (ten active + `operations`, inactive and soft-deleted since 2026-09-10 10:28:34 CST — found by the first full gate, when live fixture 298 listed only ten undeleted roles; the bootstrap now soft-deletes it too, and fixture 298 / live fixture 298 compare `is_active` and the deleted state). The seven real roles' grants: 317 rows, digest `d6fa1ea2…` before and after (dry run).

## Anonymous surface (Tim asked for the relation count before and after, on live and in the rebuild)

| measure | live before | live after | rebuild |
|---|---|---|---|
| relations `anon` holds **SELECT** on | 290 | 285 (the five row-12 tables lost it; the new `*_masked` views were never granted) | same set — derived, not counted separately: the full gate's rebuild-vs-live comparison reports no table-grant difference |
| relations `anon` holds **any** privilege on (`db/check_grants.py`, the baseline's measure) | 325 | 325 | 325 (same derivation) |
| functions `anon` may execute | 2 (`cod_verification`, `ingest_submit`) | 2 | 2 (B1 0 unexpected) |
| default privileges of `postgres` in `public` naming `anon` | 0 | 0 | **0** (was 3 before this cut's prelude §6) |

The baseline file already listed exactly the live 325 relations (its header said 326 — a stale count); it now says 325. Q1 said "shrunk to live's 290":
290 was the SELECT-only count from Step 0, the baseline measures any privilege, so on its own measure it was already equal to live and did not shrink.

## Verify chain (each verdict is the script's own exit line)

| # | step | reading |
|---|---|---|
| 1 | offline gate | `GATE_OWN_EXIT=4` first (four fixtures still asserted the old bootstrap / a container code format — fixed), then **`GATE_OWN_EXIT=0`** (`readings/gate-offline-2.txt`, 188 s) |
| 2 | backup | **`BACKUP_EXIT=0`** — main dump + 22 change_log chunks, row and seq totals equal, TOC 10,010 (`readings/backup.txt`) |
| 3 | live dry run (COMMIT→ROLLBACK) | **`DRY_OWN_EXIT=0`** (`readings/dry-run.txt`): every data digest equal before / after (seven roles' grants, user_roles, suppliers, employees, contracts, the five row-12 tables, cod_issues, certificates); reads for cfo · cco · warehouse · finance equal before / after, no-role 0 everywhere; Q7 proof as above; the migration's own `GOLIVE1_PROOF ok`. The dry run showed the new trigger function executable by `anon` — that is the platform's PUBLIC default for a new function; `apply_migration.sh` re-runs `zzz_function_grants.sql` in the same transaction, and the full gate's B1 reads 0 on live |
| 4 | apply | **`APPLY_OWN_EXIT=0`**, broken window from **2026-10-29 18:12:03 CST** (`readings/apply.txt`, `db/migration-windows.tsv`) |
| 5 | types | regenerated (+316 lines: five views, two functions); `lib/maskedTables.ts` +5 |
| 6 | tsc · build | `TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0` (after moving two count-only reads to the masked views and one unused variable) |
| 7 | full gate | first run `GATE_EXIT=1` (`readings/gate-full.txt`): ① `defacl` compared the owner's own entry, which the platform writes explicitly and a bare cluster does not — the compare now ignores `postgres=…` (same fact, two spellings); ② live fixture 265 listed the COD readers without auditor (Q2 adds `data.view_cod` to auditor); ③ live fixture 298 found `operations` soft-deleted on live — the bootstrap now soft-deletes it too. Second run **`GATE_EXIT=0`** (810 s, `readings/gate-full-2.txt`): fixtures 298–303 and live fixtures 265 · 266 · 297 · 298 ✓, verdict 6 (anon) ✓, `defacl` ✓ both sides. Final run on the final code: `readings/gate-full-final.txt` |
| 8 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 9 | layout survey | `/hr/employees/<id>/edit`, `/contracts`, `/suppliers/<SUP-2026-0003>/edit`: **390 px 3/3 usable, 0 overflow, 0 clipped**; **1280 px 3/3, 0 / 0** (`readings/layout-390.txt`, `layout-1280.txt`). The survey's session is admin (sees identity); the masked form was read in the live proof (E), not measured for width. No contract exists on live, so `/contracts/[id]` was not surveyed |
| 10 | smoke | first run **`SMOKE_EXIT=1`** with **345 ok · 24 skipped · 0 FAILED** — the only red was the smoke's own self-check: `/operation/weighbridge/[id]` sat on the expected-skip list, and live now has its first weighbridge ticket (created 2026-10-29 15:25:16 CST, before this session); the entry's own comment says to delete it on that day, so it was deleted (`readings/smoke-run1-stale-skip.txt`). Watchdog (abort rules once a minute): never fired, in-db `select 1` ≤ 1.2 ms, db / rest healthy every minute (`readings/smoke-run1-watchdog.txt`). Run 2 (final code, 20:13): **stopped at once** — the first watchdog reading was an abort signal (median of five round trips 1,779 ms > 1.5 s, in-db 0.027 ms, db / rest healthy). The watchdog had anchored to the launcher shell (its command line also contained `smoke-routes.mjs`) and killed that, so I stopped the smoke by signalling its own node process: `SMOKE_EXIT=143`, cleanup done, read-back 0 residue (`readings/smoke-run2-stopped.txt`, `smoke-run2-watchdog.txt`, `readback-after-smoke-run2.txt`). Three fresh samples then read medians 833 · 398 · 398 ms, in-db 0.02 ms — the measurement behind one retry. Run 3 (final code, 20:15, watchdog anchored with an exact match on the node process): it ran through every route and reached the last two drill-down probes (both ok) — the same point at which run 1 printed its summary — with **one FAIL: `/tools/tasks/[id]` → 503, the smoke's own words "auth unreachable, not this page broken"** (`UND_ERR_CONNECT_TIMEOUT` to `supabase.co:443`, two NETRETRY lines); the watchdog's reading just before (20:54:30) was normal (median 447 ms, in-db 0.6 ms, db / rest healthy). At 20:56 **this machine lost its network** (`ENOTFOUND` on DNS; the watchdog could read nothing and sent SIGTERM), so the cleanup could not reach Supabase and the smoke exited **`SMOKE_EXIT=6`**. Once the network was back, `npm run reap:ephemeral` reaped the plan (`REAP_OWN_EXIT=0`) and the read-back shows 0 throwaway users / roles / grants and 0 leftover smoke rows (`readings/smoke.txt`, `smoke-watchdog.txt`, `reap-after-smoke-run3.txt`, `readback-after-reap.txt`). Recorded under `docs/known-issues.md` § CWC-LIVE-INSTANCE-SWAPPING as an upstream timeout (Tim 2026-10-29); no route failed for a reason of its own in any run |
| 11 | live proof | **`GOLIVE1_PROOF_EXIT=0`, 54 PASS, 0 FAIL, 0 warnings, 0 budget refusals** (`readings/live-proof.txt`, JSON beside it): seven role clones — `/` 200; `/logistics/containers` 6 rows = database for every role, `/logistics` not restricted; `/contracts` 200 and PostgREST base price columns → 403 / 42501 while the `_masked` views → 200; employee edit page: cco · cto · gm (no `data.view_identity`) draw 3 fields 「受限」 with 0 inputs, admin · cfo · finance get the 3 inputs (the employee read is not on a work pass, so the fourth field is not drawn); supplier edit page shows the warning to every role with suppliers.view. Metal-only reader: metal_prices 12 · calendar 0 · pricing_settings 1, all = database. Anonymous: `/verify/cod/<COD-2026-0001>` 200 and names it; anon key on `collection_promise_status` → 401; `/login` 200. Portal: `/portal` 200 naming its own throwaway supplier, `/portal/certificates` 200. Nothing pressed, no form sent |
| 12 | read-back | `READBACK_OWN_EXIT=0` (`readings/readback-after-proof.txt`): 7 users / 7 enabled, roles held admin · cco · cfo · cto · finance · gm · warehouse, exactly 1 cfo grant, 0 throwaway users / roles / suppliers / orphan grants, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, SUP-2026-0003 still approved with its name, reconciliation AP 0.00 · AR 0.00 |
| 13 | COD bytes | `COD_OWN_EXIT=0`: 34,701 `ba299a4f…f42101` and 34,746 `717661f6…13a4f9`, equal to the AGENTS.md baseline and `cod_issues.sha256` |
| 14 | fresh clone, no `.env.local` | `readings/fresh-clone-build.txt` |

## Broken window — what is broken until the deploy

From 18:12:03 CST production runs v1.4.81 against this database. **`/contracts` and `/contracts/[id]` fail for every reader**: the old pages select
`sales_settlements.amount_usd`, `contract_pricing_terms.payable_pct` and the other price columns from the base tables, and those columns are no
longer granted (42501). Everything else the old app reads is unchanged (container list, supplier and employee pages, metal prices, CODs).

## Registered, not fixed

- `docs/known-issues.md` § GOLIVE1-CONTRACT-TERM-COPIES-UNMASKED — the frozen term copies on orders (`contract_document_terms`) and the terms-request
  snapshots are not masked by the price codes; live has 0 contracts and 0 copies today.

## Tim's rulings (2026-10-29, verbatim)

> Q1 - Accepted. Row 2 delivers: the anon baseline shrunk to live's 290 relations; plan 4's default-privilege revoke applied in the rebuild (db/platform-prelude.sql) and added to docs/fresh-install-checklist.md; a gate check comparing those default privileges on live and on the rebuild, with a fault injection; the wrong line in the queue corrected. Plan 3 stays deferred.
> Q2 - Accepted. Auditor: all 18 module view codes (adds module.quality.view), plus data.view_cod and data.view_change_log, keeping its five current data codes; no banking, pay, identity, health or review codes.
> Q3 - Accepted. No new gate. Employee keeps 0 codes; update its description to say it opens only the personal pages every account gets.
> Q4 - Accepted. operations and floor_display stay unchanged. Live has 11 roles after the cut, and a fresh rebuild creates the same 11.
> Q5 - Accepted. Rebuild codes: the seven real roles as live at cut time (the dated seven-roles snapshot), auditor as Q2, employee / operations / floor_display as live.
> Q6 - Accepted. action.metal_prices reads metal_prices, index_market_calendar and the stale-quote threshold table, in one change.
> Q7 - Accepted. approved, active and suspended count as approved. The edit form warns before saving that changing legal name, tax number or type sends the supplier back to review; while it is back in review the existing guards block payments and new purchase orders. Prove one supplier's return to pending_review in a rolled-back transaction on live and the full behaviour on the local rebuild.
> Q8 - Accepted. All four masked columns (work_email, work_phone, identity_no, work_pass_no): drawn as 「受限」, never sent, left unchanged by the database for a writer without data.view_identity. The new-employee page is unchanged.
> Q9 - Accepted. Customer side (settlements and customer-contract terms) masked by data.view_prices; supplier-contract terms by data.view_purchase_prices; payable_pct masked too.
> Split - Do NOT split. If you hit a real blocker that cannot fit, stop and report.
