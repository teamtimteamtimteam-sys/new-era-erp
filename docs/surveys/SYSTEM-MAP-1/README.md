# SYSTEM-MAP-1 — readings (2026-10-27, v1.4.77)

Brief: "SYSTEM-MAP-1 — menu reorganisation by business process, the single-home build check, and the four missing list pages". Rulings: `docs/system-map.md`
(2.1–2.4, plus the two SYSTEM-MAP-1 sections at the end). Started from `9e1b2930c2c620fd08ee2f2d075c9b886019f03b`. **No migration.**

**Identity of every reading:** live reads were row counts as `postgres` (`rolbypassrls`) on base tables, the reconciliation line as tim@ (`cfo`) inside a rolled-back
transaction, and the COD bytes through the Storage API (list + GET). Pages were read in a real browser through throwaway accounts made by the shared helper
(`scripts/ephemeral.mjs`, prefixes `sm1probe` / `survey` / `smoke`), each a clone of one real role's codes; nothing was pressed except menus and links.
**No sub-agent was started in this cut.**

## Verify chain (each verdict is the script's own exit line)

| # | step | reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`readings/gate-offline.txt`) |
| 2 | migration | none in this cut — no backup, dry run, apply or types |
| 3 | tsc | `TSC_OWN_EXIT=0` (`readings/tsc.txt`) |
| 4 | build | `BUILD_OWN_EXIT=0` (`readings/build.txt`) |
| 5 | full gate | `GATE_EXIT=0`, 760 s, every verdict ✓, mirrors = live (`readings/gate-full.txt`) |
| 6 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 7 | layout survey | 17 routes (the 4 new pages · one page per top-level module · `/contracts` `/finance/claims` `/finance/company` `/operation/operation-types`): **390 px 17/17, 0 overflow, 0 clipped**; **1280 px 17/17, 0 / 0** (`readings/layout-390.txt`, `layout-1280.txt`, JSON beside them). Top bar and drawer: live proof G below. |
| 8 | smoke | `SMOKE_EXIT=0`: 341 routes + probes, 25 skipped (no data), 0 failed (`readings/smoke.txt`). It reported the same 6 stale `ZZ-SMOKE-*` rows earlier cuts reported (report-only; untouched). |
| 9 | live proof | `SM1_PROOF_EXIT=0`, **111 PASS, 0 FAIL** (`readings/live-proof.txt`; menus as JSON `readings/live-proof-menus.json`). Two earlier runs during the build (96 PASS, then 111 PASS) are not kept as verdicts. |
| 10 | read-back | `READBACK_OWN_EXIT=0` (`readings/readback.txt`): 7 users / 7 enabled, roles held admin·cco·cfo·cto·finance·gm·warehouse, 1 active `cfo` grant, 0 throwaway users / roles / orphan grants, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, 0 saved views, reconciliation AP 0.00 / AR 0.00 unexplained, both agree — identical to the SYSTEM-MAP-0 reading. |
| 11 | COD bytes | `COD_OWN_EXIT=0`: 34,701 `ba299a4f…f42101` and 34,746 `717661f6…13a4f9`, equal to the AGENTS.md baseline and to `cod_issues.sha256` (`readings/cod-bytes.txt`). |
| 12 | single-home fault injection | `/inbound` given a second module → `npm run build` stops at `check-single-home` (`BUILD_WITH_INJECTION_OWN_EXIT=1`); restored byte-identical (sha256 equal), check green again (`readings/single-home-injection.txt`). The script's four built-in injections (multi · textonly · blind · unknown) each went red on the line they name. |
| 13 | fresh clone, no `.env.local` | see the end of this file |

## Live proof (`next start` on this tree against live)

**Per-role rendered menu** (desktop, 1440 px, English; every bar button opened and every row read by its `data-menu-href`):

| role (throwaway clone) | bar modules drawn 「受限」 | menu rows open / restricted (of 109) | restricted rows | Workbench |
|---|---|---|---|---|
| admin | none | 109 / 0 | — | Tasks · Reminders · My reviews · Notifications · My profile |
| cfo | none | 107 / 2 | `/logistics/shipping` `/compliance/cod` | same five |
| cco | none | 106 / 3 | `/logistics/shipping` `/finance/self-approved` `/compliance/cod` | same five |
| cto | none | 106 / 3 | `/logistics/shipping` `/finance/self-approved` `/compliance/cod` | same five |
| finance | none | 105 / 4 | `/logistics/shipping` `/finance/self-approved` `/compliance/packs` `/compliance/cod` | same five |
| gm | none | 103 / 6 | the four `/quality/*` · `/logistics/shipping` `/compliance/cod` | same five |
| warehouse | Finance | 55 / 54 | Finance 35/35 · People 11/12 (all but Overtime; incl. `/claims`) · Sales 5/11 (`/sales` quotes orders customers, `/finance/freight`) · `/tools/pricing` · `/materials` · `/compliance/packs` | same five |

For every role: the bar reads Workbench · Purchasing · Production · Quality · Sales · Finance · People · Safety · Equipment; **every one of the 109 rows sits under
exactly one module** and matches the registry's answer for that role row by row; the Tools menu is Calendar · Unit converter; the **avatar menu** is identity ·
Notifications (with unread count) · Settings · language · Log out — **no /me, no /my-reviews** (Q5).

**The four new pages** (database counts as postgres on base tables: 1 medical + 4 general claims, 3 CODs, 1 supplier certificate, 0 spare-part batches):
`/claims` opens for the six roles holding hr.view / finance.view with 5 rows, warehouse is refused by name; `/compliance/cod` opens for admin and warehouse with
3 rows, the other five are refused by name (Q4); `/compliance/supplier-certificates` 1 row and `/operation/spare-parts` 0 rows open for all seven. Each that opens
draws the export bar and sortable headers. **Masking:** cto and gm (no `data.view_health`) read the medical amount as "Restricted"; admin, cfo, cco, finance read
it as a number; every amount cell on `/claims` is "Restricted" or "<n.nn> <CCY>", never blank or 0.00.

**H (Q2):** cfo clicks CLM-2026-0004 (a general claim not yet approved) on `/claims` → soft navigation to `/finance/claims#claim-<id>`; that row is in the viewport and
highlighted (`data-hash-target="true"`, background changed).
**D (D1):** on `/purchasing/orders?status=cancelled`, clearing the status filter gives `?view=plain` with "Plain list" marked current; on `/contracts?side=buy` the
"All" link is `/contracts?view=plain`.
**G (Q1):** for admin and warehouse, English and Chinese, at 390 / 1024 / 1280 / 1440, on `/` (no search box) and `/tools/calendar` (search box): no page scrolls
sideways at any width. 390 and 1024 use the Menu drawer; 1280 and 1440 use the module row (English row 719.8 px, last button ends 871 px; right group starts at
976 px at 1280 and 1136 px at 1440 on a page with search; Chinese row 498 px). Counterfactual at 1024 with the row forced on: English last button 871 px over a
right group starting at 760 px → does not fit (Chinese would fit, but the breakpoint cannot depend on language). 390 drawer: 9 module rows + Tools + Settings, no
sideways overflow, for all seven roles.

## Assertions in the brief measured false, or not measurable
1. "nine top-level modules" names eight; with My workbench that is nine bar buttons (ruled 2026-10-27). "ten top-level items" (0.2) matched no count.
2. "the top bar … at 390 px with the new module count" — the module row is hidden below the breakpoint by construction; the count changes the drawer, not the bar.
3. D2 "each row linking to its existing detail and decision page" — general claims have no detail page; ruled as Q2.
4. "the 25 message lines naming an old home" — re-measured true (13 en + 12 zh); a wider sweep found 9 more ("HR → …") plus 4 "HR module" / 人力资源 phrases, all fixed.
5. Not measurable on live: spare parts (0 spare-part batches on live, so the page was proved empty-but-open, not with rows).

## Not done in this cut (queued)
`docs/forward-queue.md` 64d-2 (supplier-certificate status column, Q3), 64d-4 (who may read CODs, Q4), 64d-5 (the operations manual, `docs/manual-draft.md`
v1.0.1, still names old menu paths in 27 lines — re-issuing the manual is its own decision).
